// SPDX-License-Identifier: AGPL-3.0-or-lateres33

pragma solidity ^0.8.10;

import "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import "../../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "../../lib/openzeppelin-contracts-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Upgrade.sol";
import "../lzapp/OFTCoreUpgradeable.sol";
import "../interfaces/IRouter.sol";
import "../interfaces/IPair.sol";
import "../interfaces/IWETH.sol";
import "../lib/RPow.sol";
import "../lib/Ledger.sol";
import "../lzapp/IOFT.sol";

import "../IVault.sol";
import "../Blast.sol";

interface IRewardDistributor {
    function reap() external;

    function getWTLOS() external;

    function migrate() external returns (address);

    function emissionRates() external returns (address[] memory, uint256[] memory);
}

struct ES33Parameters {
    uint256 initialSupply;
    uint256 decay;
    uint256 unstakingTime;
}

contract ES33 is ERC20Upgradeable, ReentrancyGuardUpgradeable, OwnableUpgradeable, ERC1967Upgrade, BlastCommon {
    using LedgerLib for Ledger;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    constructor(address vault_) {
        vault = vault_;
        initializeBlastClaimable();
    }

    function slot(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function upgradeTo(address newImplementation) external onlyOwner {
        ERC1967Upgrade._upgradeTo(newImplementation);
    }

    function upgradeToAndCall(address newImplementation, bytes memory data) external onlyOwner {
        ERC1967Upgrade._upgradeToAndCall(newImplementation, data, true);
    }

    address distributor;
    address immutable vault;

    uint256 unstakingTime;
    uint256 emissionStart;
    uint256 emissionsSoFar;
    mapping(address => uint256) protocolFeeRate;
    Ledger staked;
    Ledger unstaking;
    EnumerableSet.AddressSet rewardTokens;

    mapping(address => uint256) public unstakingEndDate;

    mapping(IERC20 => uint256) public accruedProtocolFee;

    event Stake(address from, uint256 amount);
    event StartUnstake(address from, uint256 amount);
    event CancelUnstake(address from, uint256 amount);
    event ClaimUnstake(address from, uint256 amount);
    event Donate(address from, address token, uint256 amount);
    event Harvest(address from, uint256 amount);

    function statistics() external view returns (uint256, uint256, uint256) {
        return (staked.total, unstaking.total, emissionsSoFar);
    }

    function circulatingSupply() public view virtual returns (uint256) {
        return totalSupply();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address admin,
        address factory,
        ES33Parameters calldata params
    ) external payable initializer {
        unstakingTime = params.unstakingTime;

        _transferOwnership(admin);
        __ReentrancyGuard_init();
        __ERC20_init(name, symbol);
        ConstantProductPoolFactory(factory).deploy(
            bytes32(uint256(uint160(address(this)))), 0x000000000000000000000000EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
        );
        _mint(admin, params.initialSupply);
    }

    function stakeLiquidity(address factory, address vc, uint256 amount) external payable onlyOwner {
        transfer(address(this), amount);
        this.approve(vault, amount);
        address pool = ConstantProductPoolFactory(factory).pools(
            bytes32(uint256(uint160(address(this)))), 0x000000000000000000000000EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
        );
        IVault(vault).execute3{value: msg.value}(
            pool,
            0,
            address(this),
            0,
            int128(uint128(amount)),
            address(0),
            0,
            int128(uint128(msg.value)),
            pool,
            1,
            0,
            ""
        );
        IVault(vault).execute2(pool, 1, pool, 0, int128(uint128(IERC20(pool).balanceOf(address(this)))), vc, 0, 0, "");
    }

    function addRewardToken(address token) external onlyOwner {
        rewardTokens.add(token);
    }

    function setDistributor(address distributor_) external onlyOwner {
        distributor = distributor_;
    }

    function _mintEmission() internal returns (uint256) {
        uint256 emission = emissionCurve(block.timestamp) - emissionsSoFar;
        emissionsSoFar += emission;
        _mint(distributor, emission);
        return emission;
    }

    function mintEmission() external returns (uint256) {
        require(msg.sender == address(distributor));
        return _mintEmission();
    }

    function emissionCurve(uint256 t) public view returns (uint256) {
        if (emissionStart == 0) return 0;
        if (t < emissionStart) return 0;
        return 60_000_000e18 - 60_000_000e18 * RPow.rpow(0.99999997148112165e18, t - emissionStart, 1e18);
    }

    function setEmissionStart(uint256 t) external onlyOwner returns (uint256) {
        emissionStart = t;
    }

    function stake(uint256 amount) external nonReentrant {
        _harvest(msg.sender, true);
        staked.deposit(slot(msg.sender), amount);
        _burn(msg.sender, amount);
        _mint(address(this), amount);
        emit Stake(msg.sender, amount);
    }

    function startUnstaking() external nonReentrant {
        _harvest(msg.sender, true);
        uint256 amount = staked.withdrawAll(slot(msg.sender));
        unstaking.deposit(slot(msg.sender), amount);
        unstakingEndDate[msg.sender] = block.timestamp + unstakingTime;
        emit StartUnstake(msg.sender, amount);
    }

    function cancelUnstaking() external nonReentrant {
        _harvest(msg.sender, true);
        uint256 amount = unstaking.withdrawAll(slot(msg.sender));
        staked.deposit(slot(msg.sender), amount);

        emit CancelUnstake(msg.sender, amount);
    }

    function claimUnstaked() external nonReentrant {
        require(unstakingEndDate[msg.sender] <= block.timestamp);

        uint256 unstaked = unstaking.withdrawAll(slot(msg.sender));
        emit ClaimUnstake(msg.sender, unstaked);
        _transfer(address(this), msg.sender, unstaked);
    }

    function claimProtocolFee(IERC20 tok, address to) external onlyOwner nonReentrant {
        uint256 amount = accruedProtocolFee[tok];
        accruedProtocolFee[tok] = 0;
        tok.safeTransfer(to, amount);
    }

    function _harvest(address addr, bool reap) internal returns (uint256[] memory) {
        address[] memory tokens = rewardTokens.values();
        uint256[] memory deltas = new uint256[](tokens.length);
        uint256[] memory amounts = new uint256[](tokens.length);
        if (reap) {
            for (uint256 i = 0; i < tokens.length; i++) {
                deltas[i] = IERC20(tokens[i]).balanceOf(address(this));
            }

            (bool success,) = address(vault).call(
                abi.encodePacked(
                    hex"d3115a8a000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000020000000000000000000000004300000000000000000000000000000000000003000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000120020000000000000000000000",
                    distributor,
                    hex"000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c84499ee6934209af2ff925783aabe410d537f12000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000002000100000000000000000000000000007fffffffffffffffffffffffffffffff010200000000000000000000000000007fffffffffffffffffffffffffffffff0000000000000000000000000000000000000000000000000000000000000000"
                )
            );

            require(success);

            for (uint256 i = 0; i < tokens.length; i++) {
                deltas[i] = IERC20(tokens[i]).balanceOf(address(this)) - deltas[i];
                uint256 delta = deltas[i];
                uint256 protocolFee = (delta * protocolFeeRate[tokens[i]]) / 1e18;
                accruedProtocolFee[IERC20(tokens[i])] += protocolFee;
                staked.reward(slot(tokens[i]), (delta - protocolFee));
            }
        }

        if (addr != address(0)) {
            for (uint256 i = 0; i < tokens.length; i++) {
                uint256 harvested = staked.harvest(slot(addr), slot(tokens[i]));
                amounts[i] = harvested;

                if (harvested > 0) {
                    emit Harvest(addr, harvested);
                    IERC20(tokens[i]).safeTransfer(addr, harvested);
                }
            }
        }
        return amounts;
    }

    function setProtocolFeeRate(address token, uint256 feeRate) external onlyOwner {
        protocolFeeRate[token] = feeRate;
    }

    function harvest(bool reap) external nonReentrant returns (uint256[] memory) {
        return _harvest(msg.sender, reap);
    }

    //--- view functions
    function stakedBalanceOf(address acc) external view returns (uint256) {
        return staked.balances[slot(acc)];
    }

    function unstakingBalanceOf(address acc) external view returns (uint256) {
        return unstaking.balances[slot(acc)];
    }

    function emissionRate() external view returns (uint256) {
        return emissionCurve(block.timestamp + 1) - emissionCurve(block.timestamp);
    }

    function rewardRate() external returns (address[] memory tokens, uint256[] memory rates) {
        _harvest(address(0), true);
        (address[] memory tokens, uint256[] memory rates) = IRewardDistributor(distributor).emissionRates();
        if (staked.total == 0) {
            return (tokens, new uint256[](rates.length));
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            rates[i] = (rates[i] * (1e18 - protocolFeeRate[tokens[i]])) / staked.total;
        }
        return (tokens, rates);
    }

    receive() external payable {}
}
