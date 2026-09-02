# Aave v3 collateral hook POC

```mermaid
sequenceDiagram
    participant M as Maker wallet
    participant S as SwapVM
    participant H as AaveV3CollateralHook
    participant P as Aave v3 Pool
    participant T as Taker

    Note over M,P: Maker starts with aTokenA and zero debt
    Note over M,H: Maker approves Hook to pull aTokenA
    Note over M,S: Maker approves SwapVM for real TokenA

    T->>S: Fill order; pay TokenB
    Note over S: Taker-first transfer mode

    S->>H: Transfer TokenB<br/>(custom order receiver)
    S->>H: postTransferIn()

    H->>P: supply(TokenB, amount, maker)
    P-->>M: Mint aTokenB

    S->>H: preTransferOut()
    H->>M: Pull aTokenA
    H->>P: withdraw(TokenA, amount, maker)
    P-->>M: Send real TokenA

    S->>M: Pull real TokenA
    S-->>T: Send real TokenA

    Note over M: Final position:<br/>less aTokenA, more aTokenB
```

## Live-reserve AMM variant

`AaveV3XYCSwap` is a POC-only SwapVM extension that makes the maker's current
aToken balances the constant-product reserves. Its program encodes the two
aToken addresses and, at quote time, reads:

`reserveA = aTokenA.balanceOf(maker)` and `reserveB = aTokenB.balanceOf(maker)`.

For an exact-input trade it quotes `amountOut = amountIn * reserveOut /
(reserveIn + amountIn)`. The trader still sees and transfers only the two real
underlyings. After the quote, the hooks above supply the input and redeem the
output so the live aToken balances move to the AMM's new reserve state.

The extension is wired only into `AaveV3XYCSwapVMRouter`; the normal
`SwapVMRouter` does not accept its `0x52` opcode. This separation is deliberate
for the POC and demonstrates that the Aave layer can remain below the trader's
interface without changing the standard router.
