// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.10;

import "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import "../../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "../../lib/openzeppelin-contracts-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Upgrade.sol";
import "../lib/Ledger.sol";
import "../CToken.sol";
import "../CErc20.sol";
import "../interfaces/IRouter.sol";
import "../IVault.sol";
import "../interfaces/IWETH.sol";
import "./ES33.sol";
import "../SimplePriceOracle.sol";

interface IGauge {
    function emissionShare(address) external returns (uint256);
}

interface IComptroller {
    function getAllMarkets() external view returns (address[] memory);
}

interface VelocoreLens {
    function emissionRate(address gauge) external returns (uint256);
}

contract RewardDistributor is OwnableUpgradeable, ReentrancyGuardUpgradeable, ERC1967Upgrade, BlastCommon {
    using LedgerLib for Ledger;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    bytes32 public constant BRIBE_ACCOUNT = bytes32("BRIBE");
    ES33 public underlying;
    address immutable lens;
    address immutable gauge;
    address immutable oracle;
    address immutable vc;
    address immutable usdc;
    address immutable vault;
    IComptroller immutable comptroller;
    Ledger weights;
    mapping(bytes32 => Ledger) assetLedgers;
    mapping(address => uint256) accruedInterest;
    uint256 wtlosRate;
    uint256 lastWTLOSEmission;

    event Harvest(address addr, uint256 amount);

    constructor(
        address vault_,
        address lens_,
        address gauge_,
        address usdc_,
        address vc_,
        address oracle_,
        address comptroller_
    ) {
        vault = vault_;
        lens = lens_;
        gauge = gauge_;
        vc = vc_;
        oracle = oracle_;
        usdc = usdc_;
        comptroller = IComptroller(comptroller_);
        initializeBlastClaimable();
    }

    function upgradeToAndCall(address newImplementation, bytes memory data) external onlyOwner {
        ERC1967Upgrade._upgradeToAndCall(newImplementation, data, true);
    }

    function upgradeTo(address newImplementation) external onlyOwner {
        ERC1967Upgrade._upgradeTo(newImplementation);
    }

    function initialize(address admin, ES33 underlying_) external initializer {
        initializeBlastClaimable();
        _transferOwnership(admin);
        __ReentrancyGuard_init();
        underlying = underlying_;
    }

    // todo: takeLP
    function slot(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function slot(IERC20 a) internal pure returns (bytes32) {
        return slot(address(a));
    }

    function slot(address informationSource, bytes32 kind) public pure returns (bytes32) {
        return keccak256(abi.encode(informationSource, kind));
    }

    function onAssetIncrease(bytes32 kind, address account, uint256 delta) external nonReentrant {
        bytes32[] memory a = new bytes32[](1);
        a[0] = slot(msg.sender, kind);
        _harvest(account, a);
        Ledger storage ledger = assetLedgers[slot(msg.sender, kind)];
        ledger.deposit(slot(account), delta);
    }

    function onAssetDecrease(bytes32 kind, address account, uint256 delta) external nonReentrant {
        bytes32[] memory a = new bytes32[](1);
        a[0] = slot(msg.sender, kind);
        _harvest(account, a);
        Ledger storage ledger = assetLedgers[slot(msg.sender, kind)];
        ledger.withdraw(slot(account), delta);
    }

    function onAssetChange(bytes32 kind, address account, uint256 amount) external nonReentrant {
        bytes32[] memory a = new bytes32[](1);
        a[0] = slot(msg.sender, kind);
        _harvest(account, a);
        Ledger storage ledger = assetLedgers[slot(msg.sender, kind)];
        ledger.withdrawAll(slot(account));
        ledger.deposit(slot(account), amount);
    }

    function _harvest(address addr, bytes32[] memory ledgerIds) internal returns (uint256) {
        updateRewards(ledgerIds);
        uint256 harvested = 0;

        for (uint256 j = 0; j < ledgerIds.length; j++) {
            harvested += assetLedgers[ledgerIds[j]].harvest(slot(addr), slot(address(underlying)));
        }
        accruedInterest[addr] += harvested;
        return harvested;
    }

    function harvest(bytes32[] memory ledgerIds) external nonReentrant returns (uint256) {
        _harvest(msg.sender, ledgerIds);
        uint256 amount = accruedInterest[msg.sender];
        accruedInterest[msg.sender] = 0;
        IERC20(address(underlying)).safeTransfer(msg.sender, amount);
        emit Harvest(msg.sender, amount);
        return amount;
    }

    function updateRewards(bytes32[] memory ledgerIds) public {
        uint256 delta = underlying.mintEmission();
        if (delta != 0) {
            weights.reward(slot(address(underlying)), delta);
        }

        for (uint256 j = 0; j < ledgerIds.length; j++) {
            if (ledgerIds[j] != BRIBE_ACCOUNT) {
                uint256 amount = weights.harvest(ledgerIds[j], slot(address(underlying)));
                assetLedgers[ledgerIds[j]].reward(slot(address(underlying)), amount);
            }
        }
    }

    function setWeights(bytes32[] calldata _ids, uint256[] calldata _weights) external onlyOwner nonReentrant {
        updateRewards(_ids);
        for (uint256 i = 0; i < _ids.length; i++) {
            weights.withdrawAll(_ids[i]);
            weights.deposit(_ids[i], _weights[i]);
        }
    }

    function borrowSlot(address cToken) external pure returns (bytes32) {
        return slot(cToken, bytes32("BORROW"));
    }

    function supplySlot(address cToken) external pure returns (bytes32) {
        return slot(cToken, bytes32("SUPPLY"));
    }

    function velocore__convert(address user, bytes32[] calldata t, int128[] memory r, bytes calldata) external {
        require(msg.sender == vault, "only vault");
        require(user == address(underlying));

        address[] memory cts = comptroller.getAllMarkets();
        for (uint256 i = 0; i < cts.length; i++) {
            CToken(cts[i]).takeReserves(vault);
        }
    }

    receive() external payable {}

    //--- view functions
    function rewardRateAll()
        external
        returns (address[] memory cts, uint256[] memory supplies, uint256[] memory borrows)
    {
        cts = comptroller.getAllMarkets();
        supplies = new uint256[](cts.length);
        borrows = new uint256[](cts.length);
        uint256 totalRate = underlying.emissionRate();
        for (uint256 i = 0; i < cts.length; i++) {
            supplies[i] = CToken(cts[i]).totalSupply() == 0
                ? 0
                : ((totalRate * weights.shareOf(slot(cts[i], bytes32("SUPPLY")))) * 1e18)
                    / (CToken(cts[i]).totalSupply() * CToken(cts[i]).exchangeRateCurrent());
            borrows[i] = (CToken(cts[i]).totalBorrowsCurrent()) == 0
                ? 0
                : ((totalRate * weights.shareOf(slot(cts[i], bytes32("BORROW"))))) / (CToken(cts[i]).totalBorrowsCurrent());
        }
        return (cts, supplies, borrows);
    }

    function emissionRates() external returns (address[] memory tokens, uint256[] memory rates) {
        address[] memory cts = comptroller.getAllMarkets();
        uint256 totalUSDCRate = 0;
        for (uint256 i = 0; i < cts.length; i++) {
            CErc20 ct = CErc20(cts[i]);
            uint256 totalInterests = Math.mulDiv(ct.totalBorrowsCurrent(), ct.borrowRatePerBlock(), 1e18);
            uint256 tokenInflow = Math.mulDiv(totalInterests, ct.reserveFactorMantissa(), 1e18);
            uint256 price = SimplePriceOracle(oracle).getUnderlyingPrice(ct);
            totalUSDCRate += price * tokenInflow;
        }

        uint256 totalVCRate =
            (VelocoreLens(lens).emissionRate(gauge) * IGauge(gauge).emissionShare(address(underlying))) / 1e18;

        tokens = new address[](2);
        rates = new uint256[](2);
        tokens[0] = usdc;
        tokens[1] = vc;

        rates[0] = totalUSDCRate / (10 ** (18 - ERC20(usdc).decimals()));
        rates[1] = totalVCRate;
    }

    function bribeTokens(address) external view returns (bytes32[] memory ret) {
        ret = new bytes32[](1);
        ret[0] = bytes32(uint256(uint160(address(underlying))));
    }

    function bribeRates(address) external view returns (uint256[] memory ret) {
        ret = new uint256[](1);
        ret[0] = underlying.emissionRate() / 5;
    }

    function totalBribes(address) external view returns (uint256) {
        return 0;
    }

    function velocore__bribe(address gauge_, uint256)
        external
        returns (
            bytes32[] memory bribeTokens,
            int128[] memory deltaGauge,
            int128[] memory deltaPool,
            int128[] memory deltaExternal
        )
    {
        require(gauge_ == gauge);
        require(msg.sender == vault);

        uint256 delta = underlying.mintEmission();
        if (delta != 0) {
            weights.reward(slot(address(underlying)), delta);
        }

        uint256 bribeAmount = weights.harvest(BRIBE_ACCOUNT, slot(address(underlying)));
        underlying.approve(vault, bribeAmount);

        bribeTokens = new bytes32[](1);
        bribeTokens[0] = bytes32(uint256(uint160(address(underlying))));

        deltaExternal = new int128[](1);
        deltaExternal[0] = -int128(int256(bribeAmount));

        deltaGauge = new int128[](1);
        deltaPool = new int128[](1);
    }
}
