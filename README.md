# Capped Velodrome Stable Swap Oracle

Foundry port and simplification of the Velodrome stable-swap LP oracle focused on capped USD pricing from two Chainlink feeds.

## Contracts

- `src/CappedVeloStableSwapOracle.sol`: prices one Velodrome-style stable LP token from fair reserves.
- `src/CappedVeloStableSwapPriceFeed.sol`: Chainlink-like adapter around the single oracle.
- `src/MockChainlinkFeed.sol`: test-only Chainlink feed mock.

## Oracle Behavior

`CappedVeloStableSwapOracle` is intentionally narrow:

- only stable pools are supported;
- the LP token must have 18 decimals;
- both underlying tokens must have Chainlink feeds;
- both Chainlink feeds must report 8-decimal USD prices;
- each underlying token price is capped at `1e8` before LP pricing, so prices above $1 do not increase the reported LP value;
- non-positive underlying feed answers produce an LP price of `0`;
- zero LP token supply produces an LP price of `0`;
- pool reserves are read from `IVeloPool.metadata()` and normalized to 18 decimals;
- fair-reserve LP pricing uses the Velodrome stable invariant `x^3 * y + y^3 * x = k`.

Staleness and heartbeat checks are handled upstream. This contract forwards the older underlying feed timestamp via `getCurrentPoolPriceData()` and the price feed adapter.

## Price Feed Adapter

`CappedVeloStableSwapPriceFeed` exposes `latestRoundData()` with 8 decimals. It forwards the oracle price and the older update timestamp from the two underlying feeds.

If the source price is larger than `type(int256).max`, the adapter returns an answer of `0` rather than reverting.

## Tests

The Forge tests are fully mocked and do not require an Optimism RPC URL. Coverage includes:

- constructor validation for stable pools, LP decimals, feed presence, and feed decimals;
- token price capping at $1;
- zero, negative, stale, reverting, and overflow feed behavior;
- Chainlink-like adapter output;
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
