# Capped Velodrome Stable Swap Oracle

Foundry port and simplification of the Velodrome stable-swap LP oracle focused on capped USD pricing from two Chainlink feeds. The pool integration targets Dromos V3 stable pools.

> [!WARNING]
> Do not use this oracle for borrowable collateral. Donation attacks can manipulate the reported LP value.

## Contracts

- `src/CappedVeloStableSwapOracle.sol`: prices one Velodrome-style stable LP token from fair reserves and exposes a Chainlink-like price feed interface.
- `src/MockChainlinkFeed.sol`: test-only Chainlink feed mock.

## Oracle Behavior

`CappedVeloStableSwapOracle` is intentionally narrow:

- only Dromos V3 pools whose `POOL_TYPE` is `V2_STABLE` are supported;
- the LP token must have 18 decimals;
- both underlying tokens must have Chainlink feeds;
- both Chainlink feeds must report 8-decimal USD prices;
- each underlying token price is capped at `1e8` before LP pricing, so prices above $1 do not increase the reported LP value;
- an optional immutable minimum token price, expressed in basis points of $1, sets the effective timestamp
  to `0` when either underlying price falls below it, without changing the calculated LP price;
- non-positive underlying feed answers produce an LP price of `0`;
- zero LP token supply produces an LP price of `0`;
- pool reserves are read from the Dromos V3 six-field `IVeloPool.metadata()` and normalized to 18 decimals;
- `metadata()` is decoded positionally, so the constructor pins its shape: both decoded token slots must hold
  contracts, and `dec0`/`dec1` must equal `10 ** token.decimals()`. A pool with a different `metadata()` layout
  (for example the seven-field Velodrome/Aerodrome V2 tuple) or one reporting raw decimal counts is rejected at
  deployment instead of silently mispricing the LP;
- fair-reserve LP pricing minimizes reserve USD value on the Velodrome stable invariant
  `x^3 * y + y^3 * x = k`, corresponding to fee-free arbitrage equilibrium;
- the invariant and valuation are rounded downward; a zero computed invariant also produces a price of `0`.

Staleness and heartbeat checks are handled upstream. `latestRoundData()` returns the older underlying
timestamp unless the configured minimum-price signal overrides it with zero.

## Fair Price Derivation

The oracle prices the LP token from the pool's fair reserves rather than from the current reserve ratio. Let:

- `x` and `y` be the pool reserves normalized to 18 decimals;
- `p0` and `p1` be the capped USD prices of token0 and token1;
- `S` be total LP token supply;
- `k = x^3 * y + y^3 * x` be the Velodrome stable-pool invariant.

Fair reserves are the amounts where the pool's marginal exchange rate matches the external price ratio:

```text
p0 / p1 = y_fair * (3*x_fair^2 + y_fair^2)
          / (x_fair * (x_fair^2 + 3*y_fair^2))

price = min(p0*x_fair + p1*y_fair) / S
        subject to x_fair^3*y_fair + x_fair*y_fair^3 = k
```

This is not generally the point where both sides have equal USD value. For a balanced pool with one
token per side and one LP token outstanding, token prices of $0.50 and $1 give an arbitrage value of
approximately $1.23164345 per LP, versus $1.33748061 under the former equal-dollar model.

The implementation uses an equivalent expression that avoids simulating trades. Define
`u = x_fair + y_fair`, `v = abs(x_fair - y_fair)`, `a = p0 + p1`, and `b = abs(p0 - p1)`:

```text
k = (u^4 - v^4) / 8
reserve USD value = (a*u - b*v) / 2
```

At the minimum, `z = v/u = (b/a)^(1/3)`. Substitution gives:

```text
price = (k/2)^(1/4) * (p0+p1) * (1-z^4)^(3/4) / S
```

At equal prices, `z=0`; for a balanced pool with reserves equal to LP supply the result is exactly `2p`.
Changing the reserve ratio without changing k or S leaves this price unchanged. Fees, reserve rounding,
donations and changes to external prices are separate effects; the calculation does not protect against
donations that increase k or the token-callback read window described in the contract's NatSpec.

### Fixed-point rounding and limits

The contract keeps prices in their original 8-decimal units. It computes k with the pool-style operation
order `floor(floor(x*y/1e18) * (floor(x*x/1e18)+floor(y*y/1e18)) / 1e18)`.
Full-precision `fullMulDiv` avoids intermediate-product overflow when the quotient fits.

Roots use Solady's vendored `FixedPointMathLib`. The valuation computes the floor root of the
fully scaled integer ratio with `cbrt`, then compares its cube against the original ratio to round z
upward exactly, at 18 decimals. Rounding z upward and z^4 upward makes `1-z^4` a lower bound. Its
three-quarter power is computed by two downward integer square roots on the full 72-decimal radicand.
No tiny cubed price product is rounded in isolation.

The reserve scale is `floor((k_integer * 5e53)^(1/4))`, which is the 18-decimal representation
of `(k_real/2)^(1/4)`. It uses `sqrt(mulSqrt(k_integer, 5e53))`: `mulSqrt` handles the 512-bit product,
and two floor square roots give the exact floor fourth root. Fractional reserve precision is retained
through the supply division; the final conversion to feed units also rounds down. These operations produce
a lower bound on the analytical arbitrage value, with additional conservatism from invariant and
reserve-normalization rounding.

All positive capped feed answers from `1` ($0.00000001) to `1e8` ($1) are supported. Former price-dependent
zero cliffs are removed: when both feeds report `1`, a balanced pool with reserves equal to supply reports
`2`. A zero answer is still possible if normalized reserves or k round to zero, or if the LP value is below
the final $0.00000001 output unit.

Normalized reserves, the intermediate xy and x^2+y^2 quantities, the scaled invariant and the intermediate
valuation quotient must fit uint256; an unrepresentable result reverts. The fourth-root helper itself
supports every uint256 k. The math does not silently fall back to the former equal-dollar model.

`CappedVeloStableSwapOracle` exposes this value through the Chainlink-like `latestRoundData()` response.

## Price Feed Interface

`latestRoundData()` returns the 8-decimal LP price and effective update timestamp. `latestRoundAnswer()`
returns its answer directly. LP price and timestamp calculation is internal; the former public
`fairReservesPriceData()` function has been removed without a compatibility wrapper.

`roundId` and `answeredInRound` are always `0` and carry no information. Consumers must not use them to
detect updates or freshness. `updatedAt` is the older underlying timestamp, or `0` on a minimum-price
breach. `startedAt` always equals `updatedAt`, including when both are zero.

If the computed price is larger than `type(int256).max`, `latestRoundData()` caps the answer at
`type(int256).max`. The effective timestamp is preserved.

## Minimum-price timestamp signal

The constructor takes `(pool, token0Feed, token1Feed, minTokenPriceBps)`. The immutable
`minTokenPriceBps` applies to both underlying feeds and accepts `0` through `10000`:

| Setting | Minimum underlying price |
|---|---|
| `0` | Signal disabled |
| `1` | $0.0001 |
| `9500` | $0.95 |
| `10000` | $1 |

This is the minimum price relative to the peg, not the permitted depeg amount: a 5% tolerated depeg is
configured as `9500`, not `500`. One basis point converts exactly to `10_000` units of an 8-decimal feed.
The threshold is checked before the $1 cap; prices above $1 are healthy for this check. Equality is
healthy too: at `9500`, $0.95 passes and $0.94999999 produces zero timestamps.

A breach changes only the effective timestamp. The arbitrage valuation continues to reflect the
underlying prices. No pause state is stored: when both prices recover to at least the threshold,
the feed again reports their actual older timestamp, which may itself still be stale. The
public `getTokenPrices()` function returns `(price0, price1, updatedAt)`: both capped 8-decimal token
prices and the effective timestamp, including zero on a breach. LP valuation calls this same function
internally. Original individual feed prices and timestamps can be read from `token0Feed` and `token1Feed`.
Setting the threshold to zero preserves ordinary timestamp forwarding, including the existing zero-price response
for non-positive feed answers. With the signal enabled, those normalized zero underlying prices also
trigger zero timestamps; they still produce an LP answer of zero.

FiRM's [borrow controller](https://github.com/InverseFinance/FiRM/blob/master/src/BorrowController.sol)
checks feed age separately from its [oracle's price read](https://github.com/InverseFinance/FiRM/blob/master/src/Oracle.sol).
For a normal nonzero market staleness threshold, `updatedAt=0` makes the price stale and blocks new
borrowing. The price-only read used for liquidations still receives the current positive LP answer.
FiRM disables its staleness check when its market staleness threshold is zero, so that configuration
will not enforce this borrowing signal. This feature does not change liquidation eligibility or make
an invalid or zero answer usable, and does not remove the donation or callback restrictions above.

## Tests

The Forge tests are fully mocked and do not require an Optimism RPC URL. Coverage includes:

- constructor validation for the `V2_STABLE` pool type, LP decimals, feed presence, feed decimals, the
  `metadata()` tuple layout, and the `metadata()` decimal scalars;
- fair-reserve pricing for 6-decimal underlying tokens, exercising the reserve normalization branch;
- token price capping at $1;
- zero, negative, stale, reverting, and overflow feed behavior;
- Chainlink-like feed output;
- fair-reserve pricing at parity;
- reserve-edge stress tests, including invariant-preserving extreme pool skew and pathological one-sided reserve states;
- single-sided and correlated depegs through the smallest positive feed answer;
- 217 deterministic reference cases from an independent 80-digit Decimal solver of the marginal-price equation;
- fuzz checks for conservative reserve values, token symmetry, price monotonicity, proportional scaling,
  and exact root-rounding bounds across the full uint256 invariant range;
- threshold constructor bounds, exact basis-point conversions, both token orders, strict price boundaries,
  automatic recovery, public token-price data and disabled behavior;
- a focused FiRM-style consumer test checking stale-price rejection for borrowing and positive-price
  availability for liquidation pricing; this models feed consumption, not a full deployed-market integration.

Regenerate the offline references with `python3 script/GenerateArbitrageReferences.py`. Forge reads the
fixture without Python, network access or FFI. Constructor callers must now supply the fourth
`minTokenPriceBps` argument, and LP-price callers must use `latestRoundData()` instead of the removed
public getter. Existing immutable deployments require a new deployment to adopt these changes.

Regenerate the optional interactive visualization's current-contract dataset with:

```sh
FOUNDRY_PROFILE=visualization forge script script/GenerateOraclePriceData.s.sol:GenerateOraclePriceData --gas-limit 5000000000
```

This runs locally without broadcasting transactions. The visualization profile grants write access only
to its generated data file; the default test profile grants read access only to the reference fixtures.

## Build

```sh
forge build
```

## Test

```sh
forge test
```
