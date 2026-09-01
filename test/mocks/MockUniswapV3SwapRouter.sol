// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IUniswapV3SwapRouter } from "../../src/interfaces/IUniswapV3SwapRouter.sol";

contract MockUniswapV3SwapRouter is IUniswapV3SwapRouter {
    using SafeERC20 for IERC20;

    uint256 public rate = 1e18;

    error TooLittleReceived(uint256 received, uint256 minimum);

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn * rate / 1e18;
        if (amountOut < params.amountOutMinimum) revert TooLittleReceived(amountOut, params.amountOutMinimum);
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);
    }
}
