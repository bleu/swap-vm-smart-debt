// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IAaveV3Pool } from "../src/interfaces/IAaveV3Pool.sol";
import { IUniswapV3SwapRouter } from "../src/interfaces/IUniswapV3SwapRouter.sol";
import { AaveV3SmartDebtHook } from "../src/poc/AaveV3SmartDebtHook.sol";
import { AaveV3LeverageOpener } from "../src/poc/AaveV3LeverageOpener.sol";

/// @notice Deploys one chain's Aqua Smart Debt hook and generic leverage opener.
/// @dev Required environment: AAVE_V3_POOL, AQUA_SWAP_VM_ROUTER, and
///      UNISWAP_V3_SWAP_ROUTER. The emitted JSON is consumed by user scripts.
contract DeployAaveV3SmartDebt is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address pool = vm.envAddress("AAVE_V3_POOL");
        address aquaRouter = vm.envAddress("AQUA_SWAP_VM_ROUTER");
        address uniswapRouter = vm.envAddress("UNISWAP_V3_SWAP_ROUTER");

        vm.startBroadcast(privateKey);
        AaveV3SmartDebtHook hook = new AaveV3SmartDebtHook(IAaveV3Pool(pool), aquaRouter);
        AaveV3LeverageOpener opener = new AaveV3LeverageOpener(IAaveV3Pool(pool), IUniswapV3SwapRouter(uniswapRouter));
        vm.stopBroadcast();

        string memory key = vm.toString(block.chainid);
        string memory json = vm.serializeAddress(key, "smartDebtHook", address(hook));
        json = vm.serializeAddress(key, "leverageOpener", address(opener));
        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/", key, ".json"));
        console2.log("AaveV3SmartDebtHook deployed at", address(hook));
        console2.log("AaveV3LeverageOpener deployed at", address(opener));
    }
}
