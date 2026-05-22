# Pessimistic Velodrome LP Oracle Foundry Port

Foundry port of the Brownie-based `PessimisticVelodromeLPOracle` repo focused on:

- `PessimisticVeloSingleOracle.sol`
- `PessimisticVeloStableLpPriceFeed.sol`
- their required Solidity dependencies and mock-only Forge tests

The tests do not require an Optimism RPC URL. Velodrome pools, Chainlink feeds, swap failures, and the Optimism sequencer uptime feed are mocked in Solidity.

## Build

```sh
forge build
```

## Test

```sh
forge test
```
