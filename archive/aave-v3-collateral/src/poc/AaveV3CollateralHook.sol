// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAaveV3Pool } from "../interfaces/IAaveV3Pool.sol";
import { IMakerHooks } from "../interfaces/IMakerHooks.sol";

/// @notice POC settlement adapter for an Aave v3-backed SwapVM order.
/// @dev The maker keeps their aTokens. On a fill, incoming tokens are supplied
///      for the maker and the corresponding output aTokens are temporarily
///      pulled from the maker, redeemed, and sent back to the maker for SwapVM
///      to transfer to the taker. This is deliberately limited to zero-debt
///      positions; it is not a production position manager.
contract AaveV3CollateralHook is IMakerHooks {
    using SafeERC20 for IERC20;

    /// @notice 1.50, expressed in Aave's 18-decimal health-factor units.
    uint256 public constant DEFAULT_MIN_HEALTH_FACTOR = 1.5e18;

    IAaveV3Pool public immutable pool;
    address public immutable swapVM;
    uint256 public immutable minHealthFactor;

    /// @dev Underlying asset => its v3 aToken.
    mapping(address asset => address aToken) public aTokens;

    error OnlySwapVM();
    error UnknownReserve(address asset);
    error HealthFactorTooLow(uint256 healthFactor, uint256 minimum);
    error PartialWithdrawal(uint256 withdrawn, uint256 requested);

    constructor(IAaveV3Pool pool_, address swapVM_, address[] memory assets, address[] memory aTokens_) {
        require(assets.length == aTokens_.length, "length mismatch");
        pool = pool_;
        swapVM = swapVM_;
        minHealthFactor = DEFAULT_MIN_HEALTH_FACTOR;

        for (uint256 i; i < assets.length; ++i) aTokens[assets[i]] = aTokens_[i];
    }

    function preTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata)
        external
        view
        override
    {
        _onlySwapVM();
    }

    /// @dev The order's custom receiver must be this hook, so tokenIn has
    ///      already arrived here when this callback runs.
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
        _requireReserve(tokenIn);

        IERC20(tokenIn).forceApprove(address(pool), amountIn);
        pool.supply(tokenIn, amountIn, maker, 0);
    }

    /// @dev SwapVM calls this before pulling tokenOut from the maker. Pull the
    ///      maker's aTokens into the hook, then redeem their underlying straight
    ///      back to the maker, ready for the following SwapVM transfer.
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
        address aToken = _requireReserve(tokenOut);

        IERC20(aToken).safeTransferFrom(maker, address(this), amountOut);
        (, , , , , uint256 healthFactor) = pool.getUserAccountData(maker);
        if (healthFactor < minHealthFactor) revert HealthFactorTooLow(healthFactor, minHealthFactor);
        uint256 withdrawn = pool.withdraw(tokenOut, amountOut, maker);
        if (withdrawn != amountOut) revert PartialWithdrawal(withdrawn, amountOut);
    }

    function postTransferOut(address, address, address, address, uint256, uint256, uint256, bytes32, bytes calldata, bytes calldata)
        external
        view
        override
    {
        _onlySwapVM();
    }

    function _onlySwapVM() private view {
        if (msg.sender != swapVM) revert OnlySwapVM();
    }

    function _requireReserve(address asset) private view returns (address aToken) {
        aToken = aTokens[asset];
        if (aToken == address(0)) revert UnknownReserve(asset);
    }
}
