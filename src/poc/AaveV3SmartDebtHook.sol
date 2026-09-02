// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAaveV3Pool } from "../interfaces/IAaveV3Pool.sol";
import { IMakerHooks } from "../interfaces/IMakerHooks.sol";

interface IAquaRouter {
    function AQUA() external view returns (address);
}

/// @notice POC Smart Debt settlement adapter for an Aave v3-backed SwapVM order.
/// @dev A taker's input repays the maker's debt in tokenIn. The hook then
///      borrows tokenOut on behalf of the maker and returns it to the maker for
///      SwapVM delivery. The maker must grant the hook variable-debt credit
///      delegation for every output debt asset used in production.
contract AaveV3SmartDebtHook is IMakerHooks {
    using SafeERC20 for IERC20;

    uint256 private constant VARIABLE_RATE_MODE = 2;

    IAaveV3Pool public immutable pool;
    address public immutable aquaRouter;

    error OnlyAquaRouter();
    error RouterIsNotAquaCompatible();
    error PartialRepayment(uint256 repaid, uint256 requested);

    constructor(IAaveV3Pool pool_, address aquaRouter_) {
        if (IAquaRouter(aquaRouter_).AQUA() == address(0)) revert RouterIsNotAquaCompatible();
        pool = pool_;
        aquaRouter = aquaRouter_;
    }

    function preTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata)
        external
        view
        override
    {
        _onlySwapVM();
    }

    /// @dev The order's custom receiver must be this hook. It uses the real
    ///      token paid by the taker to reduce the maker's matching Aave debt.
    function postTransferIn(
        address maker,
        address,
        address tokenIn,
        address,
        uint256 amountIn,
        uint256,
        uint256,
        bytes32,
        bytes calldata,
        bytes calldata
    ) external override {
        _onlySwapVM();
        IERC20(tokenIn).safeTransferFrom(maker, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(pool), amountIn);
        uint256 repaid = pool.repay(tokenIn, amountIn, VARIABLE_RATE_MODE, maker);
        if (repaid != amountIn) revert PartialRepayment(repaid, amountIn);
    }

    /// @dev The repay happens first. Borrowing tokenOut then changes the debt
    ///      composition; the borrowed asset is returned to the maker for the
    ///      following normal SwapVM maker-to-taker transfer.
    function preTransferOut(
        address maker,
        address,
        address,
        address tokenOut,
        uint256,
        uint256 amountOut,
        bytes32,
        bytes calldata,
        bytes calldata
    ) external override {
        _onlySwapVM();
        pool.borrow(tokenOut, amountOut, VARIABLE_RATE_MODE, 0, maker);
        IERC20(tokenOut).safeTransfer(maker, amountOut);
    }

    function postTransferOut(address, address, address, address, uint256, uint256, uint256, bytes32, bytes calldata, bytes calldata)
        external
        view
        override
    {
        _onlySwapVM();
    }

    function _onlySwapVM() private view {
        if (msg.sender != aquaRouter) revert OnlyAquaRouter();
    }
}
