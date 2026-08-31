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
- fair-reserve LP pricing uses the Velodrome stable invariant `x^3 * y + y^3 * x = k`.

Staleness and heartbeat checks are handled upstream. This contract forwards the older underlying feed timestamp via `fairReservesPriceData()` and `latestRoundData()`.

## Fair Price Derivation

The oracle prices the LP token from the pool's fair reserves rather than from the current reserve ratio. Let:

- `x` and `y` be the pool reserves normalized to 18 decimals;
- `p0` and `p1` be the capped USD prices of token0 and token1;
- `S` be total LP token supply;
- `k = x^3 * y + y^3 * x` be the Velodrome stable-pool invariant.

Fair reserves are the reserve amounts on the same invariant where both sides of the pool have equal USD value. If the common value of each side is `q`, then:

```text
p0 * x_fair = p1 * y_fair = q
x_fair = q / p0
y_fair = q / p1
```

Substitute those fair reserves into the invariant:

```text
k = x_fair^3 * y_fair + y_fair^3 * x_fair
  = (q / p0)^3 * (q / p1) + (q / p1)^3 * (q / p0)
  = q^4 / (p0^3 * p1) + q^4 / (p1^3 * p0)
  = q^4 * (p0^2 + p1^2) / (p0^3 * p1^3)
```

Solving for `q` gives:

```text
q = ((k * p0^3 * p1^3) / (p0^2 + p1^2))^(1/4)
```

Because `q` is the fair USD value of one side of the pool, total fair pool value is `2q`. The fair LP token price is therefore:

```text
price = 2q / S
      = 2 * ((k * p0^3 * p1^3) / (p0^2 + p1^2))^(1/4) / S
```

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
- reserve-edge stress tests, including invariant-preserving extreme pool skew and pathological one-sided reserve states.

## Build

```sh
forge build
```

## Test

```sh
forge test
```
