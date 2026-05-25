// SPDX-License-Identifier: AGLP-3.0
pragma solidity ^0.8.20;

import {IChainLinkOracle} from "./interfaces/IChainLinkOracle.sol";

interface ICappedVeloStableSwapOracle {
    function pool() external view returns (address);

    function getCurrentPoolPriceData() external view returns (uint256 price, uint256 updatedAt);
}

/**
 * @title Capped Velodrome Stable Swap Price Feed
 * @notice Minimal Chainlink-like price feed adapter for a single Velodrome stable-swap oracle.
 */
contract CappedVeloStableSwapPriceFeed is IChainLinkOracle {
    ICappedVeloStableSwapOracle public immutable source;
    address public immutable pool;

    constructor(address _source) {
        source = ICappedVeloStableSwapOracle(_source);
        pool = ICappedVeloStableSwapOracle(_source).pool();
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 price;
        (price, updatedAt) = source.getCurrentPoolPriceData();
        if (price <= uint256(type(int256).max)) {
            // forge-lint: disable-next-line(unsafe-typecast)
            answer = int256(price);
        }

        return (0, answer, updatedAt, updatedAt, 0);
    }
}
