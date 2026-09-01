// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAaveV3Pool } from "../interfaces/IAaveV3Pool.sol";
import { IAaveV3FlashLoanSimpleReceiver } from "../interfaces/IAaveV3FlashLoanSimpleReceiver.sol";
import { IUniswapV3SwapRouter } from "../interfaces/IUniswapV3SwapRouter.sol";

/// @notice Opens a self-custodied Aave position with a same-asset flash loan.
/// @dev The user must approve initial collateral and delegate the selected debt
///      asset to this contract on Aave's variable-debt token before calling.
contract AaveV3LeverageOpener is IAaveV3FlashLoanSimpleReceiver {
    using SafeERC20 for IERC20;

    uint256 private constant VARIABLE_RATE_MODE = 2;

    struct OpenPositionParams {
        address positionAsset;
        address debtAsset;
        uint24 poolFee;
        uint256 initialCollateralAmount;
        uint256 flashLoanAmount;
        uint256 debtAmount;
        uint256 minPositionAssetOut;
    }

    IAaveV3Pool public immutable pool;
    IUniswapV3SwapRouter public immutable swapRouter;

    error OnlyPool();
    error InvalidFlashLoanInitiator();
    error PositionAssetMustMatchFlashAsset();
    error InsufficientPositionAssetOut(uint256 received, uint256 repayment);

    constructor(IAaveV3Pool pool_, IUniswapV3SwapRouter swapRouter_) {
        pool = pool_;
        swapRouter = swapRouter_;
    }

    function openPosition(OpenPositionParams calldata params) external {
        uint256 openingBalance = IERC20(params.positionAsset).balanceOf(address(this));
        IERC20(params.positionAsset).safeTransferFrom(msg.sender, address(this), params.initialCollateralAmount);
        pool.flashLoanSimple(address(this), params.positionAsset, params.flashLoanAmount, abi.encode(msg.sender, params), 0);
        uint256 surplus = IERC20(params.positionAsset).balanceOf(address(this)) - openingBalance;
        if (surplus != 0) {
            IERC20(params.positionAsset).forceApprove(address(pool), surplus);
            pool.supply(params.positionAsset, surplus, msg.sender, 0);
        }
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata data)
        external
        override
        returns (bool)
    {
        if (msg.sender != address(pool)) revert OnlyPool();
        if (initiator != address(this)) revert InvalidFlashLoanInitiator();

        (address owner, OpenPositionParams memory params) = abi.decode(data, (address, OpenPositionParams));
        if (params.positionAsset != asset) revert PositionAssetMustMatchFlashAsset();

        uint256 suppliedAmount = params.initialCollateralAmount + amount;
        IERC20(asset).forceApprove(address(pool), suppliedAmount);
        pool.supply(asset, suppliedAmount, owner, 0);

        pool.borrow(params.debtAsset, params.debtAmount, VARIABLE_RATE_MODE, 0, owner);
        IERC20(params.debtAsset).forceApprove(address(swapRouter), params.debtAmount);
        uint256 positionAssetOut = swapRouter.exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn: params.debtAsset,
            tokenOut: asset,
            fee: params.poolFee,
            recipient: address(this),
            amountIn: params.debtAmount,
            amountOutMinimum: params.minPositionAssetOut,
            sqrtPriceLimitX96: 0
        }));

        uint256 repayment = amount + premium;
        if (positionAssetOut < repayment) revert InsufficientPositionAssetOut(positionAssetOut, repayment);
        IERC20(asset).forceApprove(address(pool), repayment);

        return true;
    }
}
