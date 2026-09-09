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
- non-positive underlying feed answers produce an LP price of `0`;
- zero LP token supply produces an LP price of `0`;
- pool reserves are read from the Dromos V3 six-field `IVeloPool.metadata()` and normalized to 18 decimals;
- `metadata()` is decoded positionally, so the constructor pins its shape: both decoded token slots must hold
  contracts, and `dec0`/`dec1` must equal `10 ** token.decimals()`. A pool with a different `metadata()` layout
  (for example the seven-field Velodrome/Aerodrome V2 tuple) or one reporting raw decimal counts is rejected at
  deployment instead of silently mispricing the LP;
- LP pricing uses the fee-free arbitrage equilibrium of the Velodrome stable invariant
  `x^3 * y + y^3 * x = k`, with downward rounding;
- positive underlying feed answers are supported down to one 8-decimal unit (`$0.00000001`), including
  simultaneous depegs. A sufficiently small invariant or final LP value below output resolution can still
  produce a price of `0`.

Staleness and heartbeat checks are handled upstream. This contract forwards the older underlying feed timestamp via `fairReservesPriceData()` and `latestRoundData()`.

## Fair Price Derivation

The oracle values the LP at fee-free arbitrage equilibrium using the invariant, capped external prices,
and LP supply. In the following derivation all quantities are real numbers without fixed-point scaling. Let:

- `x` and `y` be the pool reserves normalized to 18 decimals;
- `p0` and `p1` be the capped USD prices of token0 and token1;
- `S` be total LP token supply;
- `k = x^3 * y + y^3 * x` be the Velodrome stable-pool invariant.

At equilibrium, the pool's marginal exchange rate matches the external price ratio:

```text
p0 / p1 = y * (3*x^2 + y^2) / (x * (x^2 + 3*y^2))
```

This is the minimum of `p0*x + p1*y` over positive reserves on the same invariant. Equal dollar values
on both sides are generally not an equilibrium condition for this curve.

A closed-form solution follows by setting `u = x+y` and `v = x-y`:

```text
k = (u^4 - v^4) / 8
value = ((p0+p1)*u + (p0-p1)*v) / 2

At equilibrium: v/u = cbrt((p1-p0)/(p0+p1))
```

Using the absolute value of this ratio gives a symmetric pricing formula:

```text
a = p0 + p1
z = cbrt(abs(p0-p1) / a)
c = 1 - z^4

price = (k/2)^(1/4) * a * c^(3/4) / S
```

When both prices equal `p`, `z` is zero and the formula reduces to `2*p*(k/2)^(1/4)/S`.
For `k=2`, `S=1`, and token prices `$0.50/$1.00`, the oracle reports `$1.23164345` per LP.
The former equal-dollar calculation reported `$1.33748060` for this example.

At fixed feed prices, the quote depends on pool state through `k^(1/4)/S`. A swap that preserves `k`
leaves the quote unchanged, and increasing `k` at fixed supply cannot lower it. Proportional liquidity
changes cancel between the fourth root of `k` and supply in exact arithmetic. Swap fees can sustain
deviations from the fee-free equilibrium used here.

The oracle reads stored reserves and live supply; token callbacks during burns can expose inconsistent
readings. Neither underlying token may hand execution to an arbitrary third party during transfers.
This deployment requirement and the donation warning above still apply.

### Rounding and Sharp Depegs

The implementation computes `k` in the same order as the stable pool's floor-rounded products. It rounds
`z` and its two squarings upward, making `c` round downward. Two floor square roots followed by floor-rounded
products compute `c^(3/4)`; taking roots before cubing retains precision when one price is much smaller
than the other. Equal prices use the simpler formula directly.

This avoids forming `p0^3*p1^3` as a tiny fixed-point intermediate. For a balanced pool with one million
normalized tokens on each side and one million LP tokens, both feeds at `$0.00099999` now produce an LP
quote of `$0.00199998`, and raising both to `$0.001122` increases the quote to `$0.00224400`. With both feeds
at their smallest positive answer, the quote is `2` in 8-decimal units.

Conservative rounding still applies to the invariant and final output. Dust liquidity can lose resolution
even with healthy feed prices, and a final LP value smaller than one 8-decimal unit rounds to zero. Arithmetic
also has a finite reserve range; this change does not make every possible `uint256` reserve state priceable.

`CappedVeloStableSwapOracle` exposes this value through both oracle-specific getters and a Chainlink-like `latestRoundData()` response.

## Price Feed Interface

`CappedVeloStableSwapOracle` exposes `latestRoundData()` with 8 decimals. It returns the LP price and the older update timestamp from the two underlying feeds. `latestRoundAnswer()` returns the `latestRoundData()` answer directly.

`roundId` and `answeredInRound` are always `0` and carry no information. Consumers must not use them to detect price updates or freshness; use `updatedAt`, which is the older underlying feed timestamp.

If the computed price is larger than `type(int256).max`, `latestRoundData()` returns an answer of `0` rather than reverting.

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
- single-token and simultaneous sharp depegs, recovery, and mixed 6-/18-decimal underlying tokens;
- deterministic references generated independently at 100 and 160 decimal digits, including dense depeg
  boundaries and different reserve/supply scales;
- fuzz properties for cube-root rounding, pool invariant matching, symmetry, feed-price monotonicity,
  invariant growth, and proportional liquidity changes.

Reference tests require the quote to be at or below the mathematical floor, within one output unit for the
canonical pool. Scaled fixtures allow `max(1, ceil(reference/1e8))` units. These bounds apply to the tested
fixtures; dust-invariant and final-output quantization are tested separately.

## Build

```sh
forge build
```

## Test

```sh
forge test
```

Run the fuzz properties with 1,000 cases each and print representative warm math-call gas costs:

```sh
forge test --fuzz-runs 1000
forge test --match-test testGasPricingSamples -vv
```

With the configured compiler and optimizer, the sample warm math calls cost approximately 2,800 gas at
parity, 7,400 gas at `$0.99/$1.00` or `$0.50/$1.00`, and 7,100 gas at `$0.00000001/$1.00`. These measurements
include the test harness call overhead and exclude pool/feed reads.

The tests read the committed fixture with a read-only Foundry permission for `test/fixtures`. They do not
invoke Python, FFI, or the network. To regenerate or verify the fixture using Python's standard library:

```sh
python3 test/fixtures/generate_equilibrium_reference.py
python3 test/fixtures/generate_equilibrium_reference.py --check
```
