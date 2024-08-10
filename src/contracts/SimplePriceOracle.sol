// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "src/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "./PriceOracle.sol";
import "./CErc20.sol";
import "./IPyth.sol";
import "./PythStructs.sol";

contract SimplePriceOracle is PriceOracle, Ownable {
    IPyth public immutable pyth;
    mapping(address => bytes32) public pythId;

    constructor(address pyth_) {
        pyth = IPyth(pyth_);
    }

    function setPriceFeed(address cToken, bytes32 pythFeedId) external onlyOwner {
        pythId[cToken] = pythFeedId;
    }

    function _getPrice(CToken cToken) internal view returns (PythStructs.Price memory) {
        bytes32 id = pythId[address(cToken)];
        require(id != bytes32(0));
        return pyth.getPriceNoOlderThan(id, 1 days);
    }

    function getUnderlyingPrice(CToken cToken) public view override returns (uint256) {
        PythStructs.Price memory price = _getPrice(cToken);
        require(price.expo >= -18, "price too precise");
        return
            (uint256(uint64(price.price)) * (10 ** uint256(uint32(36 - int32(uint32(cToken.decimals())) + price.expo))));
    }
}
