#!/usr/bin/env bash
set -euo pipefail

# Verifies the contracts recorded by DeployAaveV3SmartDebt on BaseScan.
# Required environment: ETHERSCAN_API_KEY, AAVE_V3_POOL,
# AQUA_SWAP_VM_ROUTER, and UNISWAP_V3_SWAP_ROUTER.

deployments_file="${DEPLOYMENTS_FILE:-deployments/8453.json}"

for required_var in ETHERSCAN_API_KEY AAVE_V3_POOL AQUA_SWAP_VM_ROUTER UNISWAP_V3_SWAP_ROUTER; do
    if [[ -z "${!required_var:-}" ]]; then
        echo "Missing required environment variable: ${required_var}" >&2
        exit 1
    fi
done

if [[ ! -f "$deployments_file" ]]; then
    echo "Deployment file not found: $deployments_file" >&2
    exit 1
fi

hook="$(jq -r '."8453".smartDebtHook' "$deployments_file")"
opener="$(jq -r '."8453".leverageOpener' "$deployments_file")"

if [[ "$hook" == "null" || "$opener" == "null" ]]; then
    echo "Expected smartDebtHook and leverageOpener under key 8453 in $deployments_file" >&2
    exit 1
fi

common_args=(
    --chain 8453
    --verifier etherscan
    --etherscan-api-key "$ETHERSCAN_API_KEY"
    --compiler-version v0.8.30+commit.73712a01
    --num-of-optimizations 700
    --via-ir
    --watch
)

forge verify-contract "$hook" src/poc/AaveV3SmartDebtHook.sol:AaveV3SmartDebtHook \
    --constructor-args "$(cast abi-encode 'constructor(address,address)' "$AAVE_V3_POOL" "$AQUA_SWAP_VM_ROUTER")" \
    "${common_args[@]}"

forge verify-contract "$opener" src/poc/AaveV3LeverageOpener.sol:AaveV3LeverageOpener \
    --constructor-args "$(cast abi-encode 'constructor(address,address)' "$AAVE_V3_POOL" "$UNISWAP_V3_SWAP_ROUTER")" \
    "${common_args[@]}"
