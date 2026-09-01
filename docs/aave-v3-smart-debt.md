# Aqua Aave v3 Smart Debt

The Smart Debt POC keeps an Aave position directly in the user wallet. It has
two independent user transactions:

1. `CreateAaveV3SmartDebtPosition` supplies initial WETH, receives a same-asset
   Aave flash loan, supplies both amounts for the user, borrows the initial
   debt asset through Aave credit delegation, swaps it with Uniswap V3, repays
   the flash loan, and supplies any WETH surplus.
2. The same script ships an Aqua strategy. Aqua records the user as maker; the
   Smart Debt hook uses Aqua's post-transfer-in and pre-transfer-out hooks to
   repay the input debt and borrow/deliver the output debt asset.

The hook is Aqua-only: it accepts calls only from the configured Aqua SwapVM
router. There is no protocol-specific health-factor floor; Aave validates every
supply/borrow/repay operation natively.

## Pricing and settlement

The strategy uses a 0.99–1.01 concentrated range and a 0.1% `FeeFlatIn` fee.
The curve prices from net input, while the hook receives the gross input and
requires Aave to report the entire gross amount repaid. A partial repayment
reverts the fill. The strategy starts one-sided, with capacity on the paired
debt-asset side; Aqua virtual balances subsequently enable reverse fills.

When `REQUIRE_KYC=true`, the strategy prepends Aqua's
`OnlyTakerTokenBalanceNonZero` validator for `AQUA_KYC_ACCESS_TOKEN`. A normal
taker without that NFT/token is rejected; setting the flag to `false` omits the
validator for local POC testing.

## Network configurations

The default fork RPC is `https://mainnet.base.org`. Base uses WETH collateral,
USDC as initial debt, and GHO as the paired Smart Debt asset. The Aave address
book identifies the Base pool as `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`,
USDC's variable-debt token as `0x59dca05b6c26dbd64b5381374aAaC5CD05644C28`,
and GHO's as `0x38e59ADE183BbEb94583d44213c8f3297e9933e9`.

`config/aave-v3-smart-debt.ethereum.env.example` provides the Ethereum WETH,
USDC, and DAI Aave v3 configuration. Its Aqua router and KYC issuer values are
deliberately blank: they must be the intended production Aqua deployment and
access-token issuer, not copied from Base.

## Runbook

Deploy first, then create the user position. Both scripts read `PRIVATE_KEY`
directly from the environment and use it as the broadcast signer; an RPC URL
is supplied to Forge. The create script additionally requires the
explicit asset, debt-token, amount, and deployment environment variables listed
in `config/aave-v3-smart-debt.base.env.example` (or the Ethereum equivalent).
The Base router is Uniswap's SwapRouter02, whose exact-input-single ABI omits
the legacy `deadline` field; the opener uses that deployed interface.

```bash
forge script script/DeployAaveV3SmartDebt.s.sol:DeployAaveV3SmartDebt \
  --rpc-url https://mainnet.base.org --broadcast

forge script script/CreateAaveV3SmartDebtPosition.s.sol:CreateAaveV3SmartDebtPosition \
  --rpc-url https://mainnet.base.org --broadcast
```

`Aqua.dock` only disables the shipped strategy. Closing, repaying, or
withdrawing the Aave position remains a separate user workflow.
