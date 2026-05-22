// SPDX-License-Identifier: AGLP-3.0
pragma solidity ^0.8.20;

import {IChainLinkOracle} from "./interfaces/IChainLinkOracle.sol";
import {IVeloPool} from "./interfaces/IVeloPool.sol";

interface IPessimisticVeloSingleOracle {
    function pool() external view returns (address);

    function getCurrentPoolPrice(
        bool _usePessimisticPricing
    ) external view returns (uint256);
}

/**
 * @title Pessimistic Velodrome Stable LP Price Feed
 * @notice Minimal Chainlink-like price feed adapter for a single Velodrome stable LP pessimistic oracle.
 */
contract PessimisticVeloStableLpPriceFeed is IChainLinkOracle {
    IPessimisticVeloSingleOracle public immutable source;
    address public immutable pool;

    constructor(address _source) {
        source = IPessimisticVeloSingleOracle(_source);

        address _pool = IPessimisticVeloSingleOracle(_source).pool();
        if (!IVeloPool(_pool).stable()) {
            revert("Pool must be stable");
        }
        pool = _pool;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        uint256 price = source.getCurrentPoolPrice(true);
        if (price == 0) {
            revert("Invalid price");
        }
        if (price > uint256(type(int256).max)) {
            revert("Price overflow");
        }

        return (0, int256(price), block.timestamp, block.timestamp, 0);
    }
}
