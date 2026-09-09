// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts@5.3.0/token/ERC20/extensions/IERC20Metadata.sol";
import {IVeloPool} from "./interfaces/IVeloPool.sol";
import {IChainLinkOracle} from "./interfaces/IChainLinkOracle.sol";
import {FixedPointMathLib} from "./FixedPointMathLib.sol";
import {Math} from "@openzeppelin/contracts@5.3.0/utils/math/Math.sol";

/**
 * @title Capped Velodrome Stable Swap Oracle
 * @author Original author: Yearn Finance, Modified by: Inverse Finance
 * @notice Prices Velodrome-style stable LP pools at fee-free arbitrage equilibrium using capped USD prices.
 * @dev DO NOT USE FOR BORROWABLE COLLATERAL AS ITS VALUE IS VULNERABLE TO DONATION ATTACKS
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

    /**
     * @notice Returns the current LP price and the older underlying feed update timestamp.
     * @dev `roundId` and `answeredInRound` are always 0 and carry no information. Consumers must use
     * `updatedAt`, not round identity, to detect price updates and evaluate freshness.
     * @return roundId Always 0; carries no information.
     * @return answer The current LP price with 8 decimals.
     * @return startedAt The same timestamp as `updatedAt`.
     * @return updatedAt The older update timestamp from the two underlying feeds.
     * @return answeredInRound Always 0; carries no information.
     */
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
     * non-positive. Empty pools and values below the arithmetic/output resolution also return 0.
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

    // Fee-free arbitrage-equilibrium value for x^3*y + x*y^3 = k.
    // Let a = p0+p1, z = cbrt(abs(p0-p1)/a), and c = 1-z^4.
    // The minimum pool value is (k/2)^(1/4) * a * c^(3/4).
    // Prices enter with 8 decimals; reserves and supply enter with 18.
    function _calculate_stable_lp_token_price(
        uint256 total_supply,
        uint256 price0,
        uint256 price1,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (uint256) {
        if (total_supply == 0 || price0 == 0 || price1 == 0) {
            return 0;
        }

        uint256 k = _getK(reserve0, reserve1);
        // Halving first deliberately rounds odd k down and reduces the intermediate product.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 balancedReserve = FixedPointMathLib.sqrt(FixedPointMathLib.sqrt((k / 2) * 1e18) * 1e18);
        uint256 priceSum = price0 + price1;
        if (price0 == price1) {
            return Math.mulDiv(balancedReserve, priceSum, total_supply);
        }

        uint256 difference = price0 > price1 ? price0 - price1 : price1 - price0;
        // Feed prices are capped at 1e8, so difference*1e54 fits uint256.
        // Round z upward so c, and hence the quoted value, round downward.
        uint256 z = _cbrtUp(Math.ceilDiv(difference * 1e54, priceSum));
        uint256 zSquared = Math.mulDiv(z, z, 1e18, Math.Rounding.Ceil);
        uint256 zFourth = Math.mulDiv(zSquared, zSquared, 1e18, Math.Rounding.Ceil);
        uint256 c = 1e18 - zFourth;

        // Take the fourth root before cubing to retain precision at small c.
        uint256 fourthRoot = FixedPointMathLib.sqrt(FixedPointMathLib.sqrt(c * 1e18) * 1e18);
        uint256 factor = Math.mulDiv(Math.mulDiv(fourthRoot, fourthRoot, 1e18), fourthRoot, 1e18);
        uint256 adjustedReserve = Math.mulDiv(balancedReserve, factor, 1e18);
        return Math.mulDiv(adjustedReserve, priceSum, total_supply);
    }

    // Ceiling integer cube root. The sole production caller supplies n <= 1e54.
    function _cbrtUp(uint256 n) internal pure returns (uint256 z) {
        if (n == 0) return 0;
        // A power-of-two upper bound on cbrt(n); n <= 1e54 makes the shift at most 60.
        // forge-lint: disable-next-line(incorrect-shift)
        z = 1 << ((Math.log2(n) + 3) / 3);
        while (true) {
            uint256 next = (2 * z + n / (z * z)) / 3;
            if (next >= z) break;
            z = next;
        }
        if (z * z * z < n) ++z;
    }

    function _getK(uint256 x, uint256 y) internal pure returns (uint256) {
        // Match the stable pool's order of operations and floor rounding.
        // K must also round downward for the final value to be a lower bound.
        uint256 a = Math.mulDiv(x, y, 1e18);
        uint256 b = Math.mulDiv(x, x, 1e18) + Math.mulDiv(y, y, 1e18);
        return Math.mulDiv(a, b, 1e18);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
