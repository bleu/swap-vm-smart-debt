// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { AaveV3LeverageOpener } from "../src/poc/AaveV3LeverageOpener.sol";
import { AaveV3SmartDebtHook } from "../src/poc/AaveV3SmartDebtHook.sol";
import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { XYCConcentrateSwap } from "../src/instructions/XYCConcentrate.sol";
import { FeeFlatIn } from "../src/instructions/FeeFlat.sol";
import { Salt } from "../src/instructions/Controls.sol";
import { OnlyTakerTokenBalanceNonZero } from "../src/instructions/TokenValidators.sol";

interface IVariableDebtToken {
    function approveDelegation(address delegatee, uint256 amount) external;
}

interface IAquaSwapVMRouter {
    function AQUA() external view returns (address);
}

/// @notice User-side two-transaction setup: open Aave leverage, then ship Aqua strategy.
/// @dev Every asset/debt-token address is explicitly supplied through environment
///      variables, keeping the script safe across Base and Ethereum deployments.
contract CreateAaveV3SmartDebtPosition is Script {
    function run() external {
        address owner = vm.envAddress("POSITION_OWNER");
        address router = vm.envAddress("AQUA_SWAP_VM_ROUTER");
        address positionAsset = vm.envAddress("POSITION_ASSET");
        address initialDebtAsset = vm.envAddress("INITIAL_DEBT_ASSET");
        address pairedDebtAsset = vm.envAddress("PAIRED_DEBT_ASSET");
        address initialDebtToken = vm.envAddress("INITIAL_VARIABLE_DEBT_TOKEN");
        address pairedDebtToken = vm.envAddress("PAIRED_VARIABLE_DEBT_TOKEN");
        uint256 initialCollateralAmount = vm.envUint("INITIAL_COLLATERAL_AMOUNT");
        uint256 flashLoanAmount = vm.envUint("FLASH_LOAN_AMOUNT");
        uint256 initialDebtAmount = vm.envUint("INITIAL_DEBT_AMOUNT");
        uint256 minPositionAssetOut = vm.envUint("MIN_POSITION_ASSET_OUT");
        uint256 strategyCapacity = vm.envUint("STRATEGY_CAPACITY");
        uint24 uniswapFee = uint24(vm.envUint("UNISWAP_V3_FEE"));
        bool requireKyc = vm.envOr("REQUIRE_KYC", true);

        (AaveV3LeverageOpener opener, AaveV3SmartDebtHook hook) = _loadDeployments();
        require(strategyCapacity == initialDebtAmount, "V1 capacity must equal initial debt");
        require(owner == vm.addr(vm.envUint("PRIVATE_KEY")), "owner must match broadcaster");

        Aqua aqua = Aqua(IAquaSwapVMRouter(router).AQUA());
        vm.startBroadcast();
        IERC20(positionAsset).approve(address(opener), initialCollateralAmount);
        IVariableDebtToken(initialDebtToken).approveDelegation(address(opener), initialDebtAmount);
        IERC20(initialDebtAsset).approve(address(aqua), type(uint256).max);
        IERC20(pairedDebtAsset).approve(address(aqua), type(uint256).max);
        IERC20(initialDebtAsset).approve(address(hook), type(uint256).max);
        IERC20(pairedDebtAsset).approve(address(hook), type(uint256).max);
        IVariableDebtToken(initialDebtToken).approveDelegation(address(hook), strategyCapacity);
        IVariableDebtToken(pairedDebtToken).approveDelegation(address(hook), strategyCapacity);

        opener.openPosition(AaveV3LeverageOpener.OpenPositionParams({
            positionAsset: positionAsset,
            debtAsset: initialDebtAsset,
            poolFee: uniswapFee,
            initialCollateralAmount: initialCollateralAmount,
            flashLoanAmount: flashLoanAmount,
            debtAmount: initialDebtAmount,
            minPositionAssetOut: minPositionAssetOut
        }));

        ISwapVM.Order memory order = _order(owner, initialDebtAsset, pairedDebtAsset, hook, requireKyc);
        address[] memory tokens = new address[](2);
        uint256[] memory balances = new uint256[](2);
        tokens[0] = initialDebtAsset;
        tokens[1] = pairedDebtAsset;
        if (initialDebtAsset < pairedDebtAsset) balances[1] = strategyCapacity;
        else balances[0] = strategyCapacity;
        aqua.ship(router, abi.encode(order), tokens, balances);
        vm.stopBroadcast();
    }

    function _loadDeployments() private view returns (AaveV3LeverageOpener opener, AaveV3SmartDebtHook hook) {
        string memory key = vm.toString(block.chainid);
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", key, ".json"));
        opener = AaveV3LeverageOpener(vm.parseJsonAddress(json, string.concat(".", key, ".leverageOpener")));
        hook = AaveV3SmartDebtHook(vm.parseJsonAddress(json, string.concat(".", key, ".smartDebtHook")));
    }

    function _order(address owner, address tokenA, address tokenB, AaveV3SmartDebtHook hook, bool requireKyc)
        private
        view
        returns (ISwapVM.Order memory)
    {
        address kycAccessToken = requireKyc ? vm.envAddress("AQUA_KYC_ACCESS_TOKEN") : address(0);
        bytes memory program = bytes.concat(
            requireKyc ? OnlyTakerTokenBalanceNonZero.build(kycAccessToken) : bytes(""),
            FeeFlatIn.build(10_000),
            XYCConcentrateSwap.build(Math.sqrt(0.99e36), Math.sqrt(1.01e36)),
            Salt.build(uint64(uint256(keccak256(abi.encode(block.chainid, owner, tokenA, tokenB)))))
        );
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: owner, receiver: address(0), tokenA: tokenA, tokenB: tokenB,
            shouldUnwrapWeth: false, useAquaInsteadOfSignature: true, allowZeroAmountIn: false,
            hasPreTransferInHook: false, hasPostTransferInHook: true, hasPreTransferOutHook: true, hasPostTransferOutHook: false,
            preTransferInTarget: address(0), preTransferInData: "", postTransferInTarget: address(hook), postTransferInData: "",
            preTransferOutTarget: address(hook), preTransferOutData: "", postTransferOutTarget: address(0), postTransferOutData: "", program: program
        }));
    }
}
