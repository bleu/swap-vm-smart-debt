// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAaveV3Pool } from "../../src/interfaces/IAaveV3Pool.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { AaveV3SmartDebtHook } from "../../src/poc/AaveV3SmartDebtHook.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { StaticBalances } from "../../src/instructions/Balances.sol";
import { LimitSwap } from "../../src/instructions/LimitSwap.sol";
import { Salt } from "../../src/instructions/Controls.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IVariableDebtToken is IERC20 {
    function approveDelegation(address delegatee, uint256 amount) external;
    function borrowAllowance(address fromUser, address toUser) external view returns (uint256);
}

/// @notice Opt-in integration test for Smart Debt against the real Ethereum
///         Aave v3 Pool. It proves a real variable-debt delegation lets the
///         hook borrow WETH for the maker while the taker's USDC repays debt.
contract AaveV3SmartDebtHookForkTest is Test {
    uint256 private constant FORK_BLOCK = 22_000_000;
    uint256 private constant USDC_INPUT = 20e6;
    uint256 private constant WETH_OUTPUT = 0.02 ether;

    IAaveV3Pool private constant AAVE_V3_POOL = IAaveV3Pool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IWETH private constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IVariableDebtToken private constant VARIABLE_DEBT_USDC = IVariableDebtToken(0x72E95b8931767C79bA4EeE721354d6E99a61D004);
    IVariableDebtToken private constant VARIABLE_DEBT_WETH = IVariableDebtToken(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE);

    uint256 private makerKey = 0xD3B7;
    address private maker;
    address private taker = makeAddr("fork debt taker");
    bool private forkEnabled;

    SwapVMRouter private swapVM;
    AaveV3SmartDebtHook private hook;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        forkEnabled = true;

        maker = vm.addr(makerKey);
        swapVM = new SwapVMRouter(address(0), address(WETH), address(this), "SwapVM", "1.0.0");
        hook = new AaveV3SmartDebtHook(AAVE_V3_POOL, address(swapVM));

        // Maker supplies real WETH collateral, borrows USDC, and transfers the
        // intended repayment amount to the fork-test taker.
        vm.deal(maker, 20 ether);
        vm.startPrank(maker);
        WETH.deposit{ value: 10 ether }();
        WETH.approve(address(AAVE_V3_POOL), type(uint256).max);
        AAVE_V3_POOL.supply(address(WETH), 10 ether, maker, 0);
        AAVE_V3_POOL.borrow(address(USDC), 200e6, 2, 0, maker);
        USDC.transfer(taker, USDC_INPUT);

        // This is the real authorization omitted by the mock: only this hook
        // may create up to one WETH of variable debt for the maker.
        VARIABLE_DEBT_WETH.approveDelegation(address(hook), 1 ether);
        WETH.approve(address(swapVM), type(uint256).max);
        vm.stopPrank();

        vm.prank(taker);
        USDC.approve(address(swapVM), type(uint256).max);
    }

    function testFork_RealAaveV3SmartDebtSettlementWithCreditDelegation() public {
        if (!forkEnabled) return;

        uint256 usdcDebtBefore = VARIABLE_DEBT_USDC.balanceOf(maker);
        uint256 wethDebtBefore = VARIABLE_DEBT_WETH.balanceOf(maker);
        uint256 delegationBefore = VARIABLE_DEBT_WETH.borrowAllowance(maker, address(hook));
        ISwapVM.Order memory order = _order();
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, USDC_INPUT, _takerData(abi.encodePacked(r, s, v)));

        assertEq(amountIn, USDC_INPUT);
        assertEq(amountOut, WETH_OUTPUT);
        assertEq(VARIABLE_DEBT_USDC.balanceOf(maker), usdcDebtBefore - USDC_INPUT, "USDC debt repaid");
        assertEq(VARIABLE_DEBT_WETH.balanceOf(maker), wethDebtBefore + WETH_OUTPUT, "WETH debt opened");
        assertEq(VARIABLE_DEBT_WETH.borrowAllowance(maker, address(hook)), delegationBefore - WETH_OUTPUT, "delegation spent");
        assertEq(WETH.balanceOf(taker), WETH_OUTPUT, "taker received real WETH");
    }

    function _order() private view returns (ISwapVM.Order memory) {
        bytes memory program = bytes.concat(
            StaticBalances.build(1_000e6, 1 ether), LimitSwap.build(address(USDC), address(WETH)), Salt.build(0xD3B7)
        );
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
