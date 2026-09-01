// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { AaveV3LeverageOpener } from "../src/poc/AaveV3LeverageOpener.sol";
import { MockAaveV3Pool, MockAaveV3AToken } from "./mocks/MockAaveV3Pool.sol";
import { MockUniswapV3SwapRouter } from "./mocks/MockUniswapV3SwapRouter.sol";

contract AaveV3LeverageOpenerTest is Test {
    MockAaveV3Pool internal pool;
    MockUniswapV3SwapRouter internal router;
    AaveV3LeverageOpener internal opener;
    TokenMock internal positionAsset;
    TokenMock internal debtAsset;
    MockAaveV3AToken internal aPositionAsset;
    address internal owner = makeAddr("owner");

    function setUp() public {
        pool = new MockAaveV3Pool();
        router = new MockUniswapV3SwapRouter();
        opener = new AaveV3LeverageOpener(pool, router);
        positionAsset = new TokenMock("Position", "POS");
        debtAsset = new TokenMock("Debt", "DEBT");
        aPositionAsset = MockAaveV3AToken(pool.addReserve(address(positionAsset), "Aave Position", "aPOS"));
        pool.addReserve(address(debtAsset), "Aave Debt", "aDEBT");
        pool.setFlashLoanPremiumBps(1_000);
        positionAsset.mint(owner, 10e18);
        positionAsset.mint(address(pool), 100e18);
        debtAsset.mint(address(pool), 100e18);
        positionAsset.mint(address(router), 100e18);
        router.setRate(0.6e18);
        vm.prank(owner);
        positionAsset.approve(address(opener), type(uint256).max);
    }

    function test_OpensGenericPositionRepaysFlashLoanAndSuppliesSurplus() public {
        vm.prank(owner);
        opener.openPosition(_params(10e18));

        assertEq(aPositionAsset.balanceOf(owner), 21e18, "combined collateral and swap surplus supplied");
        assertEq(pool.debt(owner, address(debtAsset)), 20e18, "debt is opened for user");
        assertEq(positionAsset.balanceOf(address(opener)), 0, "opener retains no position asset");
        assertEq(debtAsset.balanceOf(address(opener)), 0, "opener retains no debt asset");
    }

    function test_RevertsWhenSwapCannotRepayFlashLoan() public {
        router.setRate(0.5e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AaveV3LeverageOpener.InsufficientPositionAssetOut.selector, 10e18, 11e18));
        opener.openPosition(_params(10e18));
    }

    function test_RevertsWhenCallerMinOutputIsNotMet() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MockUniswapV3SwapRouter.TooLittleReceived.selector, 12e18, 13e18));
        opener.openPosition(_params(13e18));
    }

    function _params(uint256 minPositionAssetOut) private view returns (AaveV3LeverageOpener.OpenPositionParams memory) {
        return AaveV3LeverageOpener.OpenPositionParams({
            positionAsset: address(positionAsset),
            debtAsset: address(debtAsset),
            poolFee: 500,
            initialCollateralAmount: 10e18,
            flashLoanAmount: 10e18,
            debtAmount: 20e18,
            minPositionAssetOut: minPositionAssetOut
        });
    }
}
