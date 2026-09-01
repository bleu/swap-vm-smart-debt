# Aave v3 fork tests

The fork test exercises the collateral hook against the real Ethereum Aave v3
Pool at mainnet block `22,000,000`. It uses WETH, USDC, aWETH, and aUSDC from
the Aave address book; no token or lending-pool mock participates in the fill.

Set an archive-capable mainnet RPC URL, then run the fork test explicitly:

```bash
export MAINNET_RPC_URL=https://your-mainnet-rpc
corepack yarn test test/fork/AaveV3CollateralHookFork.t.sol
```

Without `MAINNET_RPC_URL`, the test is intentionally a no-op, so ordinary local
test runs stay offline and deterministic.

`AaveV3SmartDebtHookFork.t.sol` uses the same fork to test Smart Debt. The
maker supplies real WETH, borrows real USDC, and delegates WETH variable-debt
capacity to the hook. The fill repays USDC debt and opens WETH debt for the
maker, while delivering real WETH to the taker.

## Gas benchmark

`test_gas_Fork_RealAaveV3SmartCollateralAMM_exactIn` measures one exact-input
USDC -> WETH fill through the real Aave v3 Pool. It includes the custom live
aToken XYK quote, taker transfer, Aave `supply`, aToken transfer, Aave
`withdraw`, the health-factor read, and final underlying transfer to the
taker. It excludes LP setup (WETH deposit, Aave supplies, approvals, and order
signing).

Run it with the same archive RPC and the Hardhat gas-snapshot mode:

```bash
export MAINNET_RPC_URL=https://your-mainnet-rpc
npx hardhat test test/fork/AaveV3CollateralHookFork.t.sol --snapshot --grep test_gas_Fork_RealAaveV3SmartCollateralAMM_exactIn
```

The test is pinned to block `22,000,000`, preventing Aave reserve state from
changing the measured execution path between runs.
