// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @notice Minimal Aave v3 Pool surface used by the collateral hook.
/// @dev The user owns the resulting aTokens; this interface intentionally does
///      not model borrowing, debt, or the rest of the Pool API.
interface IAaveV3Pool {
    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16 referralCode)
        external;
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}
