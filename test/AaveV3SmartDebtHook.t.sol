// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "../src/routers/AquaSwapVMRouter.sol";
import { AaveV3SmartDebtHook } from "../src/poc/AaveV3SmartDebtHook.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { FeeFlatIn } from "../src/instructions/FeeFlat.sol";
import { Salt } from "../src/instructions/Controls.sol";
import { OnlyTakerTokenBalanceNonZero } from "../src/instructions/TokenValidators.sol";

import { MockAaveV3Pool } from "./mocks/MockAaveV3Pool.sol";
import { dynamic } from "./utils/Dynamic.sol";

contract AaveV3SmartDebtHookTest is Test {
    Aqua internal aqua;
    AquaSwapVMRouter internal router;
    MockAaveV3Pool internal pool;
    TokenMock internal tokenA;
    TokenMock internal tokenB;
    TokenMock internal kycToken;
    AaveV3SmartDebtHook internal hook;

    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");

    function setUp() public {
        aqua = new Aqua();
        router = new AquaSwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
        pool = new MockAaveV3Pool();
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        kycToken = new TokenMock("Aqua KYC", "KYC");
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        pool.addReserve(address(tokenA), "Aave Token A", "aTKA");
        pool.addReserve(address(tokenB), "Aave Token B", "aTKB");
        pool.setReserveRisk(address(tokenA), 2e18, 8_000);
        pool.setReserveRisk(address(tokenB), 1e18, 8_000);
        hook = new AaveV3SmartDebtHook(pool, address(router));

        tokenA.mint(maker, 100e18);
        tokenA.mint(maker, 100e18);
        tokenB.mint(address(pool), 500e18);
        vm.startPrank(maker);
        tokenA.approve(address(pool), type(uint256).max);
        pool.supply(address(tokenA), 100e18, maker, 0);
        pool.borrow(address(tokenB), 100e18, 2, 0, maker);
        tokenA.approve(address(aqua), type(uint256).max);
        tokenB.approve(address(aqua), type(uint256).max);
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function test_AquaFillPullsMakerInputRepaysGrossDebtAndPaysTaker() public {
        ISwapVM.Order memory order = _ship(_order(0), 100e18, 100e18);
        bytes32 orderHash = router.hash(order);
        _fundAndApproveTaker(tokenB, 20e18);

        vm.prank(taker);
        router.swap(order, 20e18, _takerData(false));

        uint256 expectedOut = uint256(100e18) * 20e18 / 120e18;
        assertEq(pool.debt(maker, address(tokenB)), 80e18, "gross Aqua input repaid maker debt");
        assertEq(pool.debt(maker, address(tokenA)), expectedOut, "output created maker debt");
        assertEq(tokenA.balanceOf(taker), expectedOut, "Aqua pulled borrowed output to taker");
        (uint256 balanceA, uint256 balanceB) = aqua.safeBalances(maker, address(router), orderHash, address(tokenA), address(tokenB));
        assertEq(balanceA, 100e18 - expectedOut, "Aqua output capacity decreased");
        assertEq(balanceB, 120e18, "Aqua input balance increased");
    }

    function test_AquaFillRevertsWhenGrossInputExceedsMakerDebt() public {
        ISwapVM.Order memory order = _ship(_order(0), 100e18, 100e18);
        _fundAndApproveTaker(tokenB, 120e18);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(AaveV3SmartDebtHook.PartialRepayment.selector, 100e18, 120e18));
        router.swap(order, 120e18, _takerData(false));

        assertEq(pool.debt(maker, address(tokenB)), 100e18, "reverted fill restores debt");
        assertEq(tokenB.balanceOf(taker), 120e18, "reverted fill restores taker input");
    }

    function test_AquaFillSupportsReverseDebtSwap() public {
        ISwapVM.Order memory order = _ship(_order(0), 100e18, 100e18);
        _fundAndApproveTaker(tokenB, 20e18);
        vm.prank(taker);
        router.swap(order, 20e18, _takerData(false));

        _fundAndApproveTaker(tokenA, 10e18);
        vm.prank(taker);
        router.swap(order, 10e18, _takerData(true));

        assertEq(pool.debt(maker, address(tokenA)), uint256(100e18) * 20e18 / 120e18 - 10e18, "reverse input repaid tokenA debt");
        assertGt(pool.debt(maker, address(tokenB)), 80e18, "reverse output borrowed tokenB");
        assertGt(tokenB.balanceOf(taker), 0, "taker received reverse output");
    }

    function test_AquaFeePricesFromNetInputButRepaysGrossInput() public {
        uint24 fee = 10_000;
        ISwapVM.Order memory order = _ship(_order(fee), 100e18, 100e18);
        _fundAndApproveTaker(tokenB, 20e18);

        vm.prank(taker);
        router.swap(order, 20e18, _takerData(false));

        uint256 netInput = uint256(20e18) - uint256(20e18) * fee / 1e7;
        uint256 expectedOut = uint256(100e18) * netInput / (100e18 + netInput);
        assertEq(pool.debt(maker, address(tokenB)), 80e18, "Aave receives gross input");
        assertEq(pool.debt(maker, address(tokenA)), expectedOut, "curve prices net input");
    }

    function test_RevertsWhenCalledOutsideAquaRouter() public {
        vm.expectRevert(AaveV3SmartDebtHook.OnlyAquaRouter.selector);
        hook.postTransferIn(maker, taker, address(tokenB), address(tokenA), 1, 1, 0, bytes32(0), "", "");
    }

    function test_KycValidatorRejectsNonHolderAndAllowsHolder() public {
        address kycHolder = makeAddr("kyc holder");
        ISwapVM.Order memory order = _ship(_orderWithKyc(), 100e18, 100e18);
        _fundAndApproveTaker(tokenB, 20e18);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(
            OnlyTakerTokenBalanceNonZero.TakerTokenBalanceIsZero.selector, taker, address(kycToken)
        ));
        router.swap(order, 20e18, _takerData(false));

        kycToken.mint(kycHolder, 1);
        tokenB.mint(kycHolder, 20e18);
        vm.startPrank(kycHolder);
        tokenB.approve(address(router), type(uint256).max);
        router.swap(order, 20e18, _takerDataFor(kycHolder, false));
        vm.stopPrank();

        assertGt(tokenA.balanceOf(kycHolder), 0, "eligible taker received output");
    }

    function _ship(ISwapVM.Order memory order, uint256 balanceA, uint256 balanceB) private returns (ISwapVM.Order memory) {
        vm.prank(maker);
        aqua.ship(address(router), abi.encode(order), dynamic([address(tokenA), address(tokenB)]), dynamic([balanceA, balanceB]));
        return order;
    }

    function _order(uint24 fee) private view returns (ISwapVM.Order memory) {
        return _order(bytes.concat(fee == 0 ? bytes("") : FeeFlatIn.build(fee), XYCSwap.build(), Salt.build(3)));
    }

    function _orderWithKyc() private view returns (ISwapVM.Order memory) {
        return _order(bytes.concat(OnlyTakerTokenBalanceNonZero.build(address(kycToken)), XYCSwap.build(), Salt.build(4)));
    }

    function _order(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
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

    function _fundAndApproveTaker(TokenMock token, uint256 amount) private {
        token.mint(taker, amount);
        vm.prank(taker);
        token.approve(address(router), type(uint256).max);
    }

    function _takerData(bool isAToB) private view returns (bytes memory) {
        return _takerDataFor(taker, isAToB);
    }

    function _takerDataFor(address taker_, bool isAToB) private pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker_,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: true,
            isAToB: isAToB,
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
            signature: ""
        }));
    }
}
