// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { AaveV3CollateralHook } from "../src/poc/AaveV3CollateralHook.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { StaticBalances } from "../src/instructions/Balances.sol";
import { LimitSwap } from "../src/instructions/LimitSwap.sol";
import { Salt } from "../src/instructions/Controls.sol";

import { MockAaveV3Pool, MockAaveV3AToken } from "./mocks/MockAaveV3Pool.sol";

/// @notice Proves a zero-debt v3 position can provide SwapVM liquidity while
///         the user holds aTokens rather than the quoted underlying assets.
contract AaveV3CollateralHookTest is Test {
    SwapVMRouter internal swapVM;
    MockAaveV3Pool internal pool;
    TokenMock internal tokenA;
    TokenMock internal tokenB;
    MockAaveV3AToken internal aTokenA;
    MockAaveV3AToken internal aTokenB;
    TokenMock internal usdc;
    AaveV3CollateralHook internal hook;

    uint256 internal makerKey = 0xA11CE;
    address internal maker;
    address internal taker = makeAddr("taker");

    function setUp() public {
        maker = vm.addr(makerKey);
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");
        pool = new MockAaveV3Pool();

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        usdc = new TokenMock("USD Coin", "USDC");
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);

        aTokenA = MockAaveV3AToken(pool.addReserve(address(tokenA), "Aave Token A", "aTKA"));
        aTokenB = MockAaveV3AToken(pool.addReserve(address(tokenB), "Aave Token B", "aTKB"));
        pool.addReserve(address(usdc), "Aave USD Coin", "aUSDC");
        address[] memory assets = new address[](2);
        address[] memory aTokens = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
        aTokens[0] = address(aTokenA);
        aTokens[1] = address(aTokenB);
        hook = new AaveV3CollateralHook(pool, address(swapVM), assets, aTokens);

        tokenA.mint(maker, 100e18);
        vm.startPrank(maker);
        tokenA.approve(address(pool), type(uint256).max);
        pool.supply(address(tokenA), 100e18, maker, 0);
        aTokenA.approve(address(hook), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.stopPrank();

        tokenB.mint(taker, 20e18);
        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function test_ZeroDebtPositionSwapsUnderlyingWhileMakerKeepsATokenPosition() public {
        ISwapVM.Order memory order = _order();
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 20e18, _takerData(abi.encodePacked(r, s, v)));

        assertEq(amountIn, 20e18);
        assertEq(amountOut, 10e18);
        assertEq(aTokenA.balanceOf(maker), 90e18, "output collateral was redeemed");
        assertEq(aTokenB.balanceOf(maker), 20e18, "input collateral was supplied");
        assertEq(tokenA.balanceOf(taker), 10e18, "taker received real output token");
        assertEq(tokenB.balanceOf(taker), 0, "taker paid real input token");
        assertEq(tokenA.balanceOf(maker), 0, "maker does not retain quoted underlying");
        assertEq(tokenB.balanceOf(address(hook)), 0, "hook supplied all received input");
    }

    function test_RevertsWhenDebtWouldLeaveHealthFactorBelowOnePointFive() public {
        // TokenA is worth $2, TokenB is worth $0.50, and each has an 80% LT.
        // The fill would change the position from $200 to $190 collateral.
        pool.setReserveRisk(address(tokenA), 2e18, 8_000);
        pool.setReserveRisk(address(tokenB), 0.5e18, 8_000);
        usdc.mint(address(pool), 130e18);
        vm.prank(maker);
        pool.borrow(address(usdc), 130e18, 2, 0, maker);

        ISwapVM.Order memory order = _order();
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);

        vm.prank(taker);
        vm.expectRevert();
        swapVM.swap(order, 20e18, _takerData(abi.encodePacked(r, s, v)));

        assertEq(aTokenA.balanceOf(maker), 100e18, "failed fill leaves input collateral untouched");
        assertEq(aTokenB.balanceOf(maker), 0, "failed fill supplies nothing");
    }

    function test_RevertsWhenOraclePricesChangeBeforeTheFill() public {
        usdc.mint(address(pool), 50e18);
        vm.prank(maker);
        pool.borrow(address(usdc), 50e18, 2, 0, maker);

        // The position was opened under the initial $1 prices. Before its
        // public order is filled, Aave's oracle marks both collaterals down.
        pool.setReserveRisk(address(tokenA), 0.5e18, 8_000);
        pool.setReserveRisk(address(tokenB), 0.25e18, 8_000);

        ISwapVM.Order memory order = _order();
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(AaveV3CollateralHook.HealthFactorTooLow.selector, 0.8e18, 1.5e18));
        swapVM.swap(order, 20e18, _takerData(abi.encodePacked(r, s, v)));

        assertEq(aTokenA.balanceOf(maker), 100e18, "oracle-change rejection is atomic");
        assertEq(aTokenB.balanceOf(maker), 0, "input was not supplied");
    }

    function test_AllowsFillExactlyAtHealthFactorBoundary() public {
        // Before: 100 A * $1 * 90% = $90 adjusted collateral, with $59 debt.
        // After: 90 A * $1 * 90% + 20 B * $0.50 * 75% = $88.50.
        // 88.50 / 59 = 1.50 exactly, which the inclusive guard permits.
        pool.setReserveRisk(address(tokenA), 1e18, 9_000);
        pool.setReserveRisk(address(tokenB), 0.5e18, 7_500);
        usdc.mint(address(pool), 59e18);
        vm.prank(maker);
        pool.borrow(address(usdc), 59e18, 2, 0, maker);

        ISwapVM.Order memory order = _order();
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);

        vm.prank(taker);
        swapVM.swap(order, 20e18, _takerData(abi.encodePacked(r, s, v)));

        (, , , , , uint256 healthFactor) = pool.getUserAccountData(maker);
        assertEq(healthFactor, 1.5e18, "boundary fill is allowed");
    }

    function test_RevertsWhenFillCrossesTheHealthFactorBoundary() public {
        pool.setReserveRisk(address(tokenA), 1e18, 9_000);
        pool.setReserveRisk(address(tokenB), 0.5e18, 7_500);
        usdc.mint(address(pool), 59e18);
        vm.prank(maker);
        pool.borrow(address(usdc), 59e18, 2, 0, maker);
        tokenB.mint(taker, 2e18);

        ISwapVM.Order memory order = _order();
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);

        // 22 B buys 11 A. It lowers the adjusted collateral below $88.50.
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(AaveV3CollateralHook.HealthFactorTooLow.selector, 1_497_457_627_118_644_067, 1.5e18)
        );
        swapVM.swap(order, 22e18, _takerData(abi.encodePacked(r, s, v)));

        assertEq(aTokenA.balanceOf(maker), 100e18, "unsafe boundary crossing is atomic");
        assertEq(aTokenB.balanceOf(maker), 0);
    }

    function test_RevertsWhenAaveReportsAShortWithdrawal() public {
        pool.setWithdrawCap(address(tokenA), 9e18);
        ISwapVM.Order memory order = _order();
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(AaveV3CollateralHook.PartialWithdrawal.selector, 9e18, 10e18));
        swapVM.swap(order, 20e18, _takerData(abi.encodePacked(r, s, v)));

        assertEq(aTokenA.balanceOf(maker), 100e18, "reverted fill restores redeemed collateral");
        assertEq(aTokenB.balanceOf(maker), 0, "reverted fill restores supplied collateral");
        assertEq(tokenB.balanceOf(taker), 20e18, "reverted fill restores taker input");
    }

    function test_AttackerCannotCallHookDirectlyToSpendMakerATokenAllowance() public {
        vm.prank(taker);
        vm.expectRevert(AaveV3CollateralHook.OnlySwapVM.selector);
        hook.preTransferOut(
            maker, taker, address(tokenB), address(tokenA), 20e18, 10e18, bytes32(0), "", ""
        );

        assertEq(aTokenA.balanceOf(maker), 100e18, "direct caller cannot pull approved aTokens");
        assertEq(tokenA.balanceOf(taker), 0, "direct caller receives no underlying");
    }

    function test_AttackerCannotUseSwapVMWithForgedMakerAuthorization() public {
        ISwapVM.Order memory order = _order();
        // This is a structurally valid signature payload, but was not made by `maker`.
        bytes memory forgedSignature = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.prank(taker);
        vm.expectRevert();
        swapVM.swap(order, 20e18, _takerData(forgedSignature));

        assertEq(aTokenA.balanceOf(maker), 100e18, "forged order cannot pull approved aTokens");
        assertEq(aTokenB.balanceOf(maker), 0, "forged order cannot add collateral either");
        assertEq(tokenB.balanceOf(taker), 20e18, "forged order cannot pull taker input");
        assertEq(tokenA.balanceOf(taker), 0, "forged order cannot send output");
    }

    function _order() private view returns (ISwapVM.Order memory) {
        bytes memory program = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            LimitSwap.build(address(tokenB), address(tokenA)),
            Salt.build(1)
        );
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(hook),
            tokenA: address(tokenA),
            tokenB: address(tokenB),
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
            isAToB: false,
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
