// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { AaveV3CollateralHook } from "../src/poc/AaveV3CollateralHook.sol";
import { AaveV3XYCSwap } from "../src/poc/AaveV3XYCSwap.sol";
import { AaveV3XYCSwapVMRouter } from "../src/poc/AaveV3XYCSwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { Salt } from "../src/instructions/Controls.sol";

import { MockAaveV3Pool, MockAaveV3AToken } from "./mocks/MockAaveV3Pool.sol";

/// @notice Proves a constant-product order can quote directly from the maker's
///         live Aave position, while a trader only transfers underlying tokens.
contract AaveV3XYCSwapTest is Test {
    AaveV3XYCSwapVMRouter internal swapVM;
    MockAaveV3Pool internal pool;
    TokenMock internal tokenA;
    TokenMock internal tokenB;
    MockAaveV3AToken internal aTokenA;
    MockAaveV3AToken internal aTokenB;
    AaveV3CollateralHook internal hook;

    uint256 internal makerKey = 0xA11CE;
    address internal maker;
    address internal taker = makeAddr("taker");

    function setUp() public {
        maker = vm.addr(makerKey);
        swapVM = new AaveV3XYCSwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");
        pool = new MockAaveV3Pool();

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);

        aTokenA = MockAaveV3AToken(pool.addReserve(address(tokenA), "Aave Token A", "aTKA"));
        aTokenB = MockAaveV3AToken(pool.addReserve(address(tokenB), "Aave Token B", "aTKB"));
        address[] memory assets = new address[](2);
        address[] memory aTokens = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
        aTokens[0] = address(aTokenA);
        aTokens[1] = address(aTokenB);
        hook = new AaveV3CollateralHook(pool, address(swapVM), assets, aTokens);

        tokenA.mint(maker, 100e18);
        tokenB.mint(maker, 100e18);
        vm.startPrank(maker);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.supply(address(tokenA), 100e18, maker, 0);
        pool.supply(address(tokenB), 100e18, maker, 0);
        aTokenA.approve(address(hook), type(uint256).max);
        aTokenB.approve(address(hook), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.stopPrank();

        tokenB.mint(taker, 10e18);
        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function test_QuotesFromLiveATokenBalancesAndSettlesUnderlying() public {
        ISwapVM.Order memory order = _order();
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 10e18, _takerData(abi.encodePacked(r, s, v)));

        // 10 * 100 / (100 + 10), taken from aToken balances at execution time.
        uint256 expectedOut = uint256(10e18) * 100e18 / 110e18;
        assertEq(amountIn, 10e18);
        assertEq(amountOut, expectedOut);
        assertEq(aTokenA.balanceOf(maker), 100e18 - expectedOut, "A reserve redeemed for the taker");
        assertEq(aTokenB.balanceOf(maker), 110e18, "B reserve supplied from the taker");
        assertEq(tokenA.balanceOf(taker), expectedOut, "trader receives underlying A");
        assertEq(tokenB.balanceOf(taker), 0, "trader pays underlying B");
        assertEq(tokenA.balanceOf(address(hook)), 0);
        assertEq(tokenB.balanceOf(address(hook)), 0);
    }

    function test_QuoteIncludesAccruedATokenInterest() public {
        // Aave aTokens grow with accrued supply interest. The curve must read
        // that live balance rather than rely on the original deposit amount.
        pool.accrueInterest(address(tokenA), maker, 5e18);
        ISwapVM.Order memory order = _order();
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, 10e18, _takerData(abi.encodePacked(r, s, v)));

        uint256 expectedOut = uint256(10e18) * 105e18 / 110e18;
        assertEq(amountOut, expectedOut, "quote uses accrued aToken reserve");
        assertEq(aTokenA.balanceOf(maker), 105e18 - expectedOut);
    }

    function _order() private view returns (ISwapVM.Order memory) {
        bytes memory program = bytes.concat(AaveV3XYCSwap.build(address(aTokenA), address(aTokenB)), Salt.build(1));
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
