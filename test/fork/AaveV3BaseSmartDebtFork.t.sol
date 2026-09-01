// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAaveV3Pool } from "../../src/interfaces/IAaveV3Pool.sol";
import { IUniswapV3SwapRouter } from "../../src/interfaces/IUniswapV3SwapRouter.sol";
import { AaveV3LeverageOpener } from "../../src/poc/AaveV3LeverageOpener.sol";
import { AaveV3SmartDebtHook } from "../../src/poc/AaveV3SmartDebtHook.sol";

interface IWETH is IERC20 { function deposit() external payable; }
interface IVariableDebtToken is IERC20 { function approveDelegation(address delegatee, uint256 amount) external; }

/// @notice Opt-in Base integration suite. Set RUN_BASE_FORK=true to run it;
///         BASE_RPC_URL defaults to the public Base endpoint.
contract AaveV3BaseSmartDebtForkTest is Test {
    uint256 private constant BASE_BLOCK = 50_750_734;
    address private constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address private constant AQUA_ROUTER = 0x111111338c5091E8440b67B168bAe16a668AC0De;
    IAaveV3Pool private constant POOL = IAaveV3Pool(0xA238Dd80C259a72e81d7e4664a9801593F98d1c5);
    IUniswapV3SwapRouter private constant UNISWAP = IUniswapV3SwapRouter(0x2626664c2603336E57B271c5C0b26F421741e481);
    IWETH private constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    IERC20 private constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 private constant GHO = IERC20(0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee);
    IVariableDebtToken private constant V_USDC = IVariableDebtToken(0x59dca05b6c26dbd64b5381374aAaC5CD05644C28);
    IVariableDebtToken private constant V_GHO = IVariableDebtToken(0x38e59ADE183BbEb94583d44213c8f3297e9933e9);
    IERC20 private constant KYC = IERC20(0x26FFc7D378E8e49Be2c483295A3e3E511F96a468);
    address private constant KYC_HOLDER = 0x0beEa0e1f3D79CB55633530E291336DAb9a7d82d;

    bool private enabled;

    function setUp() public {
        if (!vm.envOr("RUN_BASE_FORK", false)) return;
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")), BASE_BLOCK);
        enabled = true;
    }

    function testFork_BaseDeploymentsAndKycHolderAreAvailable() public view {
        if (!enabled) return;
        assertGt(AQUA.code.length, 0, "Aqua deployed");
        assertGt(AQUA_ROUTER.code.length, 0, "Aqua router deployed");
        assertGt(address(POOL).code.length, 0, "Aave pool deployed");
        assertGt(KYC.balanceOf(KYC_HOLDER), 0, "pinned KYC holder remains eligible");
    }

    function testFork_LeverageOpenerRepaysFlashLoanAndSuppliesPosition() public {
        if (!enabled) return;
        address owner = makeAddr("base position owner");
        AaveV3LeverageOpener opener = new AaveV3LeverageOpener(POOL, UNISWAP);
        vm.deal(owner, 2 ether);
        vm.startPrank(owner);
        WETH.deposit{value: 1 ether}();
        WETH.approve(address(opener), type(uint256).max);
        V_USDC.approveDelegation(address(opener), 3_500e6);
        opener.openPosition(AaveV3LeverageOpener.OpenPositionParams({
            positionAsset: address(WETH), debtAsset: address(USDC), poolFee: 500,
            initialCollateralAmount: 1 ether, flashLoanAmount: 1 ether,
            debtAmount: 3_500e6, minPositionAssetOut: 1_001e15
        }));
        vm.stopPrank();
        assertGt(V_USDC.balanceOf(owner), 0, "USDC variable debt opened");
    }
}
