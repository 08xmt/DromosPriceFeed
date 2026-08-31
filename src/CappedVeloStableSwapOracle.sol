// SPDX-License-Identifier: AGLP-3.0
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts@5.3.0/token/ERC20/extensions/IERC20Metadata.sol";
import {IVeloPool} from "./interfaces/IVeloPool.sol";
import {IChainLinkOracle} from "./interfaces/IChainLinkOracle.sol";
import {FixedPointMathLib} from "./FixedPointMathLib.sol";

/**
 * @title Capped Velodrome Stable Swap Oracle
 * @author Original author: Yearn Finance, Modified by: Inverse Finance
 * @notice This oracle may be used to price Velodrome-style stable LP pools using fair reserves.
 * @dev DO NOT USE FOR BORROWABLE COLLATERAL AS IT's VULNERABLE TO DONATION ATTACKS
 *  Both pool tokens must have Chainlink USD feeds. Each token price is capped at 1 USD before the LP price is
 *  calculated, so upward moves above peg do not increase the reported LP value.
 *
 *  metadata() is decoded positionally, so the constructor pins the tuple to the shape this oracle expects:
 *  both decoded token slots must hold contracts, and dec0/dec1 must equal 10 ** token.decimals(). A pool
 *  with a different metadata() layout, or one reporting raw decimal counts, is rejected at deployment
 *  rather than silently mispricing the LP.
 *
 *  DEPLOYMENT REQUIREMENT: neither pool token may hand execution to an attacker or arbitrary third party
 *  during transfer or transferFrom. No ERC-777/ERC-1363-style hooks, no callback on receipt, no transfer
 *  logic that calls an address the caller controls. This is a hard requirement, not a preference, and it
 *  cannot be enforced on-chain here - the deployer must verify it for both tokens before deployment.
 *
 *  Why: this oracle reads the pool's stored reserves and its live totalSupply as a coupled pair with no
 *  atomicity guard. A Velodrome-style burn() reduces totalSupply, then transfers both tokens out, then
 *  updates reserves. A token that calls back during those transfers lets an attacker read this oracle
 *  mid-burn, with totalSupply already reduced and reserves still pre-burn, inflating the reported LP price
 *  by totalSupply_before / totalSupply_after. That ratio is unbounded: burning 90% of supply reports a 10x
 *  price. metadata() is an unguarded view, so the pool's own reentrancy lock does not close this window.
 */

contract CappedVeloStableSwapOracle is IChainLinkOracle {
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
    uint8 internal constant ORACLE_DECIMALS = 8;
    uint256 internal constant ORACLE_SCALE = 10 ** ORACLE_DECIMALS;
    uint256 internal constant ONE_USD = 100_000_000;
    bytes32 internal constant STABLE_POOL_TYPE = "V2_STABLE";

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
        if (poolContract.POOL_TYPE() != STABLE_POOL_TYPE) {
            revert("Pool must be stable");
        }
        (uint256 _decimals0, uint256 _decimals1,,, address _token0, address _token1) = poolContract.metadata();

        // metadata() is decoded positionally, so a pool whose tuple layout differs from IVeloPool
        // would decode silently into the wrong fields. Both token slots must hold real contracts.
        if (_token0.code.length == 0 || _token1.code.length == 0) {
            revert("Bad metadata layout");
        }

        // The reserve normalization in fairReservesPriceData() divides by these scalars, and the
        // price is linear in the result. They must be 10 ** token.decimals(), not the raw count.
        if (
            _decimals0 != 10 ** uint256(IERC20Metadata(_token0).decimals())
                || _decimals1 != 10 ** uint256(IERC20Metadata(_token1).decimals())
        ) {
            revert("Bad metadata decimals");
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

    function decimals() external pure override returns (uint8) {
        return ORACLE_DECIMALS;
    }

    function latestRoundData()
        public
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 price;
        (price, updatedAt) = fairReservesPriceData();
        if (price <= uint256(type(int256).max)) {
            // forge-lint: disable-next-line(unsafe-typecast)
            answer = int256(price);
        }

        return (0, answer, updatedAt, updatedAt, 0);
    }

    function latestRoundAnswer() external view returns (int256 answer) {
        (, answer,,,) = latestRoundData();
    }

    /**
     * @notice Check the last time a token's Chainlink price was updated.
     * @dev Useful for external checks if a price is stale.
     * @param _tokenIndex The index of the token to get the price of (0 or 1).
     * @return updatedAt The timestamp of our last price update.
     */
    function chainlinkPriceLastUpdated(uint256 _tokenIndex) external view returns (uint256 updatedAt) {
        (, updatedAt) = _getChainlinkPriceData(_tokenIndex);
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

    /*
     * @notice Gets the current fair-reserve price and oldest underlying feed update time for the configured
     * Velodrome LP token.
     * @return fairReservesPricing The current fair-reserve price of one LP token, or 0 if an underlying answer is
     * non-positive.
     * @return updatedAt The older update timestamp from the two underlying feeds.
     * @dev The stored reserves read here and the live totalSupply read below are a coupled pair, and this
     * function does not guard their atomicity. Correctness depends on the deployment requirement in the
     * contract NatSpec: neither pool token may hand execution to a third party during transfer. Without
     * that, a mid-burn read sees a reduced totalSupply against pre-burn reserves and overprices the LP.
     */
    function fairReservesPriceData() public view returns (uint256 fairReservesPricing, uint256 updatedAt) {
        // get what we need to calculate our reserves and pricing
        IVeloPool poolContract = IVeloPool(pool);
        (
            uint256 decimals0, // note that this will be "1e18"", not "18"
            uint256 decimals1,
            uint256 reserve0,
            uint256 reserve1,,
        ) = poolContract.metadata();

        // make sure our reserves are normalized to 18 decimals (looking at you, USDC)
        reserve0 = (reserve0 * DECIMALS) / decimals0;
        reserve1 = (reserve1 * DECIMALS) / decimals1;

        // pull our prices
        (uint256 price0, uint256 price1, uint256 lastUpdatedAt) = _getTokenPricesData();
        updatedAt = lastUpdatedAt;

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
        price0 *= 1e18 / ORACLE_SCALE; // convert to 18 dec
        price1 *= 1e18 / ORACLE_SCALE;
        uint256 a = FixedPointMathLib.rpow(price0, 3, 1e18); // keep same decimals as chainlink
        uint256 b = FixedPointMathLib.rpow(price1, 3, 1e18);
        uint256 c = FixedPointMathLib.rpow(price0, 2, 1e18);
        uint256 d = FixedPointMathLib.rpow(price1, 2, 1e18);

        uint256 p0 = k * FixedPointMathLib.mulWadDown(a, b); // 2*18 decimals

        uint256 fair = p0 / (c + d); // number of decimals is 18

        // each sqrt divides the num decimals by 2. So need to replenish the decimals midway through with another 1e18
        uint256 frth_fair = FixedPointMathLib.sqrt(FixedPointMathLib.sqrt(fair * 1e18) * 1e18); // number of decimals is 18

        return 2 * ((frth_fair * ORACLE_SCALE) / total_supply); // converts to chainlink decimals
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
