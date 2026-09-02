// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAaveV3Pool } from "../../src/interfaces/IAaveV3Pool.sol";
import { IAaveV3FlashLoanSimpleReceiver } from "../../src/interfaces/IAaveV3FlashLoanSimpleReceiver.sol";

contract MockAaveV3AToken is ERC20 {
    address public immutable pool;

    error OnlyPool();

    constructor(string memory name, string memory symbol, address pool_) ERC20(name, symbol) {
        pool = pool_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != pool) revert OnlyPool();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != pool) revert OnlyPool();
        _burn(from, amount);
    }
}

/// @notice Minimal, 1:1 Aave v3 pool model used only by the collateral POC.
contract MockAaveV3Pool is IAaveV3Pool {
    using SafeERC20 for IERC20;

    struct Reserve {
        MockAaveV3AToken aToken;
        uint256 price;
        uint256 liquidationThresholdBps;
    }

    mapping(address asset => Reserve) internal reserves;
    address[] internal reserveList;
    mapping(address user => mapping(address asset => uint256 amount)) public debt;
    mapping(address asset => uint256 amount) public withdrawCap;
    mapping(address asset => bool enabled) public hasWithdrawCap;
    uint256 public flashLoanPremiumBps;

    error ReserveNotFound(address asset);
    error FlashLoanCallbackFailed();

    function setFlashLoanPremiumBps(uint256 premiumBps) external {
        flashLoanPremiumBps = premiumBps;
    }

    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16)
        external
        override
    {
        _aToken(asset);
        uint256 premium = amount * flashLoanPremiumBps / 10_000;
        IERC20(asset).safeTransfer(receiverAddress, amount);
        if (!IAaveV3FlashLoanSimpleReceiver(receiverAddress).executeOperation(asset, amount, premium, msg.sender, params)) {
            revert FlashLoanCallbackFailed();
        }
        IERC20(asset).safeTransferFrom(receiverAddress, address(this), amount + premium);
    }

    function addReserve(address asset, string calldata name, string calldata symbol) external returns (address) {
        reserves[asset] = Reserve({
            aToken: new MockAaveV3AToken(name, symbol, address(this)),
            price: 1e18,
            liquidationThresholdBps: 8_000
        });
        reserveList.push(asset);
        return address(reserves[asset].aToken);
    }

    function setReserveRisk(address asset, uint256 price, uint256 liquidationThresholdBps) external {
        Reserve storage reserve = reserves[asset];
        if (address(reserve.aToken) == address(0)) revert ReserveNotFound(asset);
        reserve.price = price;
        reserve.liquidationThresholdBps = liquidationThresholdBps;
    }

    /// @dev Test-only switch to model a pool that reports a short withdrawal.
    function setWithdrawCap(address asset, uint256 amount) external {
        _aToken(asset);
        withdrawCap[asset] = amount;
        hasWithdrawCap[asset] = true;
    }

    /// @dev Test-only interest accrual: aTokens are rebasing in real Aave.
    function accrueInterest(address asset, address user, uint256 amount) external {
        _aToken(asset).mint(user, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external override {
        _aToken(asset);
        debt[onBehalfOf][asset] += amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external override returns (uint256) {
        _aToken(asset);
        uint256 repaid = amount > debt[onBehalfOf][asset] ? debt[onBehalfOf][asset] : amount;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), repaid);
        debt[onBehalfOf][asset] -= repaid;
        return repaid;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        MockAaveV3AToken aToken = _aToken(asset);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        MockAaveV3AToken aToken = _aToken(asset);
        uint256 withdrawn = hasWithdrawCap[asset] && amount > withdrawCap[asset] ? withdrawCap[asset] : amount;
        aToken.burn(msg.sender, withdrawn);
        IERC20(asset).safeTransfer(to, withdrawn);
        return withdrawn;
    }

    function getUserAccountData(address user)
        external
        view
        override
        returns (uint256, uint256 totalDebtBase, uint256, uint256 currentLiquidationThreshold, uint256, uint256 healthFactor)
    {
        uint256 totalCollateralBase;
        uint256 adjustedCollateralBase;
        for (uint256 i; i < reserveList.length; ++i) {
            Reserve storage reserve = reserves[reserveList[i]];
            uint256 collateralValue = reserve.aToken.balanceOf(user) * reserve.price / 1e18;
            totalCollateralBase += collateralValue;
            adjustedCollateralBase += collateralValue * reserve.liquidationThresholdBps / 10_000;
            totalDebtBase += debt[user][reserveList[i]] * reserve.price / 1e18;
        }

        currentLiquidationThreshold = totalCollateralBase == 0 ? 0 : adjustedCollateralBase * 10_000 / totalCollateralBase;
        healthFactor = totalDebtBase == 0 ? type(uint256).max : adjustedCollateralBase * 1e18 / totalDebtBase;
        return (totalCollateralBase, totalDebtBase, 0, currentLiquidationThreshold, 0, healthFactor);
    }

    function _aToken(address asset) private view returns (MockAaveV3AToken aToken) {
        aToken = reserves[asset].aToken;
        if (address(aToken) == address(0)) revert ReserveNotFound(asset);
    }
}
