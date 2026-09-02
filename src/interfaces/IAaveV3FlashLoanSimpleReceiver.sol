// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

interface IAaveV3FlashLoanSimpleReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);
}
