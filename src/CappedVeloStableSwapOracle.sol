// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts@5.3.0/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts@5.3.0/utils/math/Math.sol";
import {IVeloPool} from "./interfaces/IVeloPool.sol";
import {IChainLinkOracle} from "./interfaces/IChainLinkOracle.sol";
import {FixedPointMathLib} from "./FixedPointMathLib.sol";

/**
 * @title Capped Velodrome Stable Swap Oracle
 * @author Inverse Finance
 * @notice Prices Velodrome-style stable LP pools at their fee-free arbitrage equilibrium value.
 * @dev DO NOT USE FOR BORROWABLE COLLATERAL AS ITS VALUE IS VULNERABLE TO DONATION ATTACKS
 *  Both pool tokens must have Chainlink USD feeds. Each token price is capped at 1 USD before the LP price is
 *  calculated, so upward moves above peg do not increase the reported LP value.
 *  If either underlying price is below minTokenPriceBps of the $1 peg, the effective
 *  timestamp is zero while the LP price is still calculated. A threshold of zero disables this signal.
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

    /// @notice Minimum underlying price in basis points of $1; 9500 means $0.95, 0 disables the signal.
    uint256 public immutable minTokenPriceBps;

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
     * @param _minTokenPriceBps Minimum underlying price in basis points of $1 (0 disables, maximum 10000).
     */
    constructor(address _pool, address _token0Feed, address _token1Feed, uint256 _minTokenPriceBps) {
        if (_minTokenPriceBps > 10_000) revert("Threshold exceeds 10000 bps");
        minTokenPriceBps = _minTokenPriceBps;
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

        // The reserve normalization in _getLpPriceData() divides by these scalars, and the
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
     * @notice Returns the current LP price and its effective update timestamp.
     * @dev `roundId` and `answeredInRound` are always 0 and carry no information. Consumers must use
     * `updatedAt`, not round identity, to detect price updates and evaluate freshness.
     * @return roundId Always 0; carries no information.
     * @return answer The current LP price with 8 decimals, capped at type(int256).max.
     * @return startedAt The same timestamp as `updatedAt`.
     * @return updatedAt Zero if either price is below the enabled threshold; otherwise the older feed timestamp.
     * @return answeredInRound Always 0; carries no information.
     */
    function latestRoundData()
        public
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 price;
        (price, updatedAt) = _getLpPriceData();
        if (price <= uint256(type(int256).max)) {
            // forge-lint: disable-next-line(unsafe-typecast)
            answer = int256(price);
        } else {
            answer = type(int256).max;
        }

        return (0, answer, updatedAt, updatedAt, 0);
    }

    function latestRoundAnswer() external view returns (int256 answer) {
        (, answer,,,) = latestRoundData();
    }

    /**
     * @notice Returns both capped token prices and their effective update timestamp.
     * @return price0 Token0 USD price capped at $1, with 8 decimals; 0 for a non-positive answer.
     * @return price1 Token1 USD price capped at $1, with 8 decimals; 0 for a non-positive answer.
     * @return updatedAt Zero on a threshold breach; otherwise the older underlying timestamp.
     */
    function getTokenPrices() public view returns (uint256 price0, uint256 price1, uint256 updatedAt) {
        uint256 updatedAt0;
        uint256 updatedAt1;

        (price0, updatedAt0) = _getChainlinkPriceData(token0Feed);
        (price1, updatedAt1) = _getChainlinkPriceData(token1Feed);

        // One basis point of the $1 peg is exactly 10_000 units of an 8-decimal feed.
        // When disabled, thresholdPrice is zero and even normalized non-positive answers do not trip it.
        uint256 thresholdPrice = minTokenPriceBps * ONE_USD / 10_000;
        updatedAt = price0 < thresholdPrice || price1 < thresholdPrice ? 0 : _min(updatedAt0, updatedAt1);
        price0 = _min(price0, ONE_USD);
        price1 = _min(price1, ONE_USD);
    }

    /* ========== HELPER VIEW FUNCTIONS ========== */

    /**
     * @notice Gets the current arbitrage LP price and effective update timestamp.
     * @return price The current LP price, or 0 if an underlying answer is non-positive.
     * @return updatedAt Zero on a threshold breach; otherwise the older underlying timestamp.
     * @dev The stored reserves read here and the live totalSupply read below are a coupled pair, and this
     * function does not guard their atomicity. Correctness depends on the deployment requirement in the
     * contract NatSpec: neither pool token may hand execution to a third party during transfer. Without
     * that, a mid-burn read sees a reduced totalSupply against pre-burn reserves and overprices the LP.
     */
    function _getLpPriceData() internal view returns (uint256 price, uint256 updatedAt) {
        // get what we need to calculate our reserves and pricing
        IVeloPool poolContract = IVeloPool(pool);
        (
            uint256 decimals0, // note that this will be "1e18"", not "18"
            uint256 decimals1,
            uint256 reserve0,
            uint256 reserve1,,
        ) = poolContract.metadata();

        // make sure our reserves are normalized to 18 decimals (looking at you, USDC)
        reserve0 = Math.mulDiv(reserve0, DECIMALS, decimals0);
        reserve1 = Math.mulDiv(reserve1, DECIMALS, decimals1);

        // pull our prices
        (uint256 price0, uint256 price1, uint256 lastUpdatedAt) = getTokenPrices();
        updatedAt = lastUpdatedAt;

        if (price0 == 0 || price1 == 0) {
            return (0, updatedAt);
        }

        price = _calculate_stable_lp_token_price(poolContract.totalSupply(), price0, price1, reserve0, reserve1);
    }

    function _getChainlinkPriceData(address _feed) internal view returns (uint256 currentPrice, uint256 updatedAt) {
        if (_feed != token0Feed && _feed != token1Feed) {
            revert("bad feed");
        }

        int256 price;
        (, price,, updatedAt,) = IChainLinkOracle(_feed).latestRoundData();

        if (price > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            currentPrice = uint256(price);
        }
    }

    /// @dev Minimum of p0*x+p1*y on x^3*y+x*y^3=k, divided by supply.
    /// With u=x+y and v=abs(x-y), k=(u^4-v^4)/8. At the minimum,
    /// z=v/u=cbrt(abs(p0-p1)/(p0+p1)), giving value=(k/2)^0.25*(p0+p1)*(1-z^4)^0.75.
    /// Prices remain in feed units. Roots and products round toward a lower valuation.
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
        if (k == 0) return 0;

        uint256 sum = price0 + price1;
        uint256 difference = price0 > price1 ? price0 - price1 : price1 - price0;
        uint256 shape = DECIMALS;
        if (difference != 0) {
            uint256 z = _cubeRootRatioUp(difference, sum);
            // z is an upper bound; ceil(z^4 / 1e54) preserves a lower bound on 1-z^4.
            uint256 m = DECIMALS - Math.ceilDiv((z * z) * (z * z), 1e54);
            // Keep the full 72-decimal radicand instead of flooring m^3 onto a wad grid.
            shape = FixedPointMathLib.sqrt(FixedPointMathLib.sqrt(m * m * m * DECIMALS));
        }

        uint256 reserveScale = _fourthRootK(k);
        // Keep shape's fractional reserve precision through the supply division.
        // reserveScale < 2^109, shape <= 1e18 and sum <= 2e8, so this product fits.
        return Math.mulDiv(reserveScale * shape, sum, total_supply) / DECIMALS;
    }

    /// @dev ceil(1e18 * cbrt(numerator/denominator)). Inputs are capped feed prices:
    /// 0 < numerator < denominator <= 2e8, so every cube comparison fits uint256.
    /// The enclosing interval halves each step, requiring at most 60 iterations.
    function _cubeRootRatioUp(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (numerator == 0) return 0;
        uint256 low;
        uint256 high = DECIMALS;
        uint256 target = numerator * 1e54;
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            if (mid * mid * mid * denominator < target) {
                low = mid;
            } else {
                high = mid;
            }
        }
        return high;
    }

    /// @dev floor(1e18 * (k_real/2)^0.25), where k=k_real*1e18.
    /// The radicand k*5e53 may exceed uint256; compare fourth powers in 512 bits.
    /// Its root is strictly below 2^109 for every uint256 k. At most 109 iterations;
    /// mid^2 fits uint256, and Math.mul512 supplies both words of mid^4.
    function _fourthRootK(uint256 k) internal pure returns (uint256) {
        if (k == 0) return 0;
        (uint256 targetHigh, uint256 targetLow) = Math.mul512(k, 5e53);
        uint256 low;
        uint256 high = uint256(1) << 109;
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            uint256 squared = mid * mid;
            (uint256 powerHigh, uint256 powerLow) = Math.mul512(squared, squared);
            if (powerHigh < targetHigh || (powerHigh == targetHigh && powerLow <= targetLow)) {
                low = mid;
            } else {
                high = mid;
            }
        }
        return low;
    }

    /// @dev Same order as the pool invariant xy(x^2+y^2), with every division floored.
    function _getK(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 a = Math.mulDiv(x, y, DECIMALS);
        uint256 b = Math.mulDiv(x, x, DECIMALS) + Math.mulDiv(y, y, DECIMALS);
        return Math.mulDiv(a, b, DECIMALS);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
