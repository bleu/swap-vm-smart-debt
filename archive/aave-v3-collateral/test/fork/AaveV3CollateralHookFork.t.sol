// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAaveV3Pool } from "../../src/interfaces/IAaveV3Pool.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { AaveV3CollateralHook } from "../../src/poc/AaveV3CollateralHook.sol";
import { AaveV3XYCSwap } from "../../src/poc/AaveV3XYCSwap.sol";
import { AaveV3XYCSwapVMRouter } from "../../src/poc/AaveV3XYCSwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { Salt } from "../../src/instructions/Controls.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

/// @notice Integration test against a pinned Ethereum mainnet Aave v3 state.
/// @dev Set MAINNET_RPC_URL to execute the fork. Without it, the test is a
///      no-op so the ordinary local test suite remains self-contained.
contract AaveV3CollateralHookForkTest is Test {
    uint256 private constant FORK_BLOCK = 22_000_000;

    IAaveV3Pool private constant AAVE_V3_POOL = IAaveV3Pool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IWETH private constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 private constant AWETH = IERC20(0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8);
    IERC20 private constant AUSDC = IERC20(0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c);

    uint256 private makerKey = 0xF0A7;
    address private maker;
    address private taker = makeAddr("fork taker");
    bool private forkEnabled;

    AaveV3XYCSwapVMRouter private swapVM;
    AaveV3CollateralHook private hook;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        forkEnabled = true;

        maker = vm.addr(makerKey);
        swapVM = new AaveV3XYCSwapVMRouter(address(0), address(WETH), address(this), "SwapVM", "1.0.0");

        address[] memory assets = new address[](2);
        address[] memory aTokens = new address[](2);
        assets[0] = address(USDC);
        assets[1] = address(WETH);
        aTokens[0] = address(AUSDC);
        aTokens[1] = address(AWETH);
        hook = new AaveV3CollateralHook(AAVE_V3_POOL, address(swapVM), assets, aTokens);

        // Fund the maker with real WETH, then borrow and re-supply USDC. This
        // produces real aWETH/aUSDC reserves without any token or pool mock.
        vm.deal(maker, 20 ether);
        vm.startPrank(maker);
        WETH.deposit{ value: 10 ether }();
        WETH.approve(address(AAVE_V3_POOL), type(uint256).max);
        AAVE_V3_POOL.supply(address(WETH), 10 ether, maker, 0);
        AAVE_V3_POOL.borrow(address(USDC), 5_001e6, 2, 0, maker);
        USDC.transfer(taker, 1e6);
        USDC.approve(address(AAVE_V3_POOL), type(uint256).max);
        AAVE_V3_POOL.supply(address(USDC), 5_000e6, maker, 0);
        AWETH.approve(address(hook), type(uint256).max);
        AUSDC.approve(address(hook), type(uint256).max);
        WETH.approve(address(swapVM), type(uint256).max);
        vm.stopPrank();

        vm.prank(taker);
        USDC.approve(address(swapVM), type(uint256).max);
    }

    function testFork_RealAaveV3CollateralSettlement() public {
        if (!forkEnabled) return;

        uint256 aWethBefore = AWETH.balanceOf(maker);
        uint256 aUsdcBefore = AUSDC.balanceOf(maker);
        ISwapVM.Order memory order = _order();
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 1e6, _takerData(abi.encodePacked(r, s, v)));

        assertEq(amountIn, 1e6, "taker input");
        uint256 expectedOut = 1e6 * aWethBefore / (aUsdcBefore + 1e6);
        assertEq(amountOut, expectedOut, "constant-product output");
        assertEq(AUSDC.balanceOf(maker), aUsdcBefore + amountIn, "real Aave minted aUSDC to maker");
        assertEq(AWETH.balanceOf(maker), aWethBefore - amountOut, "real Aave redeemed aWETH");
        assertEq(WETH.balanceOf(taker), amountOut, "taker received real WETH");
        (, , , , , uint256 healthFactor) = AAVE_V3_POOL.getUserAccountData(maker);
        assertGe(healthFactor, hook.minHealthFactor(), "post-fill HF floor");
    }

    function test_gas_Fork_RealAaveV3SmartCollateralAMM_exactIn() public {
        if (!forkEnabled) return;

        ISwapVM.Order memory order = _order();
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);

        vm.prank(taker);
        vm.startSnapshotGas("AaveV3SmartCollateralAMM_swap_exactIn_realAave");
        swapVM.swap(order, 1e6, _takerData(abi.encodePacked(r, s, v)));
        vm.stopSnapshotGas();
    }

    function _order() private view returns (ISwapVM.Order memory) {
        // The curve uses the maker's real aToken balances at execution time.
        bytes memory program = bytes.concat(AaveV3XYCSwap.build(address(AUSDC), address(AWETH)), Salt.build(0xAA0E));
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(hook),
            tokenA: address(USDC),
            tokenB: address(WETH),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            hasPreTransferInHook: false,
            hasPostTransferInHook: true,
            hasPreTransferOutHook: true,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(hook),
            postTransferInData: "",
            preTransferOutTarget: address(hook),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: program
        }));
    }

    function _takerData(bytes memory signature) private view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));
    }
}
