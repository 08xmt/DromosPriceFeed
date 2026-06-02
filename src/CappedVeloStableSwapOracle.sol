// SPDX-License-Identifier: AGLP-3.0
pragma solidity ^0.8.20;

import {IVeloPool} from "./interfaces/IVeloPool.sol";
import {IChainLinkOracle} from "./interfaces/IChainLinkOracle.sol";
import {FixedPointMathLib} from "./FixedPointMathLib.sol";

/**
 * @title Capped Velodrome Stable Swap Oracle
 * @author Original author: Yearn Finance, Modified by: Inverse Finance
 * @notice This oracle may be used to price Velodrome-style stable LP pools using fair reserves.
 *  Both pool tokens must have Chainlink USD feeds. Each token price is capped at 1 USD before the LP price is
 *  calculated, so upward moves above peg do not increase the reported LP value.
 */

contract CappedVeloStableSwapOracle {
    /* ========== STATE VARIABLES ========== */
    /// @notice Address of the pool for this oracle.
    address public immutable pool;

    /// @notice Address of the pool's token0.
    address public immutable token0;

    /// @notice Address of the Chainlink price feed for token0.
    address public immutable token0Feed;

    /// @notice Address of the pool's token1.
    address public immutable token1;

    /// @notice Address of the Chainlink price feed for token1.
    address public immutable token1Feed;

    // our pool/LP token decimals, just in case velodrome has weird pools in the future with different decimals
    uint256 internal constant DECIMALS = 10 ** 18;
    uint256 internal constant ORACLE_DECIMALS = 8;
    uint256 internal constant ONE_USD = 100_000_000;

    /* ========== CONSTRUCTOR ========== */
    /**
     * @param _pool Address of the Velodrome pool this oracle is pricing.
     * @param _token0Feed The Chainlink feed for token0.
     * @param _token1Feed The Chainlink feed for token1.
     */
    constructor(address _pool, address _token0Feed, address _token1Feed) {
        // set the pool in the constructor, pull token0 and token1 from that
        pool = _pool;
        IVeloPool poolContract = IVeloPool(_pool);
        if (poolContract.decimals() != 18) {
            revert("Lp token must have 18 decimals");
        }
        (,,,, bool isStable, address _token0, address _token1) = poolContract.metadata();
        if (!isStable) {
            revert("Pool must be stable");
        }
        token0 = _token0;
        token1 = _token1;
        token0Feed = _token0Feed;
        token1Feed = _token1Feed;

        if (_token0Feed == address(0) || _token1Feed == address(0)) {
            revert("Both tokens must have CL oracle");
        }

        // we always expect 8 decimals for USD pricing
        if (
            IChainLinkOracle(_token0Feed).decimals() != ORACLE_DECIMALS
                || IChainLinkOracle(_token1Feed).decimals() != ORACLE_DECIMALS
        ) {
            revert("Must be 8 decimals");
        }
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Check the last time a token's Chainlink price was updated.
     * @dev Useful for external checks if a price is stale.
     * @param _tokenIndex The index of the token to get the price of (0 or 1).
     * @return updatedAt The timestamp of our last price update.
     */
    function chainlinkPriceLastUpdated(uint256 _tokenIndex) external view returns (uint256 updatedAt) {
        (, updatedAt) = _getChainlinkPriceData(_tokenIndex);
    }

    /*
     * @notice Gets the current price of a our Velodrome LP token.
     * @return The current price of one LP token.
     */
    function getCurrentPoolPrice() public view returns (uint256 price) {
        (price,) = _getFairReservesPricingData(pool);
    }

    /*
     * @notice Gets the current price and oldest underlying feed update time for a Velodrome LP token.
     * @return price The current price of one LP token, or 0 if an underlying answer is non-positive.
     * @return updatedAt The older update timestamp from the two underlying feeds.
     */
    function getCurrentPoolPriceData() external view returns (uint256 price, uint256 updatedAt) {
        return _getFairReservesPricingData(pool);
    }

    /**
     * @notice Returns the Chainlink feed price of the given token address.
     * @dev Returns 0 if the feed answer is non-positive. Staleness is not enforced here.
     * @param _tokenIndex The index of the token to get the price of (0 or 1).
     * @return currentPrice The current price of the underlying token.
     */
    function getChainlinkPrice(uint256 _tokenIndex) public view returns (uint256 currentPrice) {
        (currentPrice,) = _getChainlinkPriceData(_tokenIndex);
    }

    /// @notice Returns token Chainlink prices capped at 1 USD, with 8 decimals.
    function getTokenPrices() public view returns (uint256 price0, uint256 price1) {
        (price0, price1,) = _getTokenPricesData();
    }

    /* ========== HELPER VIEW FUNCTIONS ========== */

    function _getFairReservesPricingData(address _pool)
        internal
        view
        returns (uint256 fairReservesPricing, uint256 updatedAt)
    {
        // get what we need to calculate our reserves and pricing
        IVeloPool poolContract = IVeloPool(_pool);
        (
            uint256 decimals0, // note that this will be "1e18"", not "18"
            uint256 decimals1,
            uint256 reserve0,
            uint256 reserve1,
            ,
            ,

        ) = poolContract.metadata();

        // make sure our reserves are normalized to 18 decimals (looking at you, USDC)
        reserve0 = (reserve0 * DECIMALS) / decimals0;
        reserve1 = (reserve1 * DECIMALS) / decimals1;

        // pull our prices
        (uint256 price0, uint256 price1, uint256 pricesUpdatedAt) = _getTokenPricesData();
        updatedAt = pricesUpdatedAt;

        if (price0 == 0 || price1 == 0) {
            return (0, updatedAt);
        }

        fairReservesPricing =
            _calculate_stable_lp_token_price(poolContract.totalSupply(), price0, price1, reserve0, reserve1);
    }

    function _getTokenPricesData() internal view returns (uint256 price0, uint256 price1, uint256 updatedAt) {
        uint256 updatedAt0;
        uint256 updatedAt1;

        (price0, updatedAt0) = _getChainlinkPriceData(0);
        (price1, updatedAt1) = _getChainlinkPriceData(1);

        price0 = _min(price0, ONE_USD);
        price1 = _min(price1, ONE_USD);
        updatedAt = _min(updatedAt0, updatedAt1);
    }

    function _getChainlinkPriceData(uint256 _tokenIndex)
        internal
        view
        returns (uint256 currentPrice, uint256 updatedAt)
    {
        if (_tokenIndex > 1) {
            revert("bad index");
        }

        int256 price;
        (, price,, updatedAt,) = IChainLinkOracle(_tokenIndex == 0 ? token0Feed : token1Feed).latestRoundData();

        if (price > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            currentPrice = uint256(price);
        }
    }

    // solves for cases where curve is x^3 * y + y^3 * x = k
    // fair reserves math formula author: @ksyao2002
    function _calculate_stable_lp_token_price(
        uint256 total_supply,
        uint256 price0,
        uint256 price1,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (uint256) {
        if (total_supply == 0) {
            return 0;
        }

        uint256 k = _getK(reserve0, reserve1);
        // fair_reserves = ( (k * (price0 ** 3) * (price1 ** 3)) )^(1/4) / ((price0 ** 2) + (price1 ** 2));
        price0 *= 1e18 / (10 ** ORACLE_DECIMALS); // convert to 18 dec
        price1 *= 1e18 / (10 ** ORACLE_DECIMALS);
        uint256 a = FixedPointMathLib.rpow(price0, 3, 1e18); // keep same decimals as chainlink
        uint256 b = FixedPointMathLib.rpow(price1, 3, 1e18);
        uint256 c = FixedPointMathLib.rpow(price0, 2, 1e18);
        uint256 d = FixedPointMathLib.rpow(price1, 2, 1e18);

        uint256 p0 = k * FixedPointMathLib.mulWadDown(a, b); // 2*18 decimals

        uint256 fair = p0 / (c + d); // number of decimals is 18

        // each sqrt divides the num decimals by 2. So need to replenish the decimals midway through with another 1e18
        uint256 frth_fair = FixedPointMathLib.sqrt(FixedPointMathLib.sqrt(fair * 1e18) * 1e18); // number of decimals is 18

        return 2 * ((frth_fair * (10 ** ORACLE_DECIMALS)) / total_supply); // converts to chainlink decimals
    }

    function _getK(uint256 x, uint256 y) internal pure returns (uint256) {
        //x, n, scalar
        uint256 x_cubed = FixedPointMathLib.rpow(x, 3, 1e18);
        uint256 newX = FixedPointMathLib.mulWadDown(x_cubed, y);
        uint256 y_cubed = FixedPointMathLib.rpow(y, 3, 1e18);
        uint256 newY = FixedPointMathLib.mulWadDown(y_cubed, x);

        return newX + newY; // 18 decimals
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
