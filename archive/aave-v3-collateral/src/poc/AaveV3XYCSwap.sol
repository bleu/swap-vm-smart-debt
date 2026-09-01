// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";

/// @notice Constant-product curve whose reserves are a maker's Aave aTokens.
/// @dev Encoding: [aTokenA, aTokenB], where aTokenA maps to the order's
///      lower-address underlying token. The settlement hook redeems/supplies
///      the corresponding underlying assets after this instruction quotes.
library AaveV3XYCSwap {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;
    using Math for uint256;
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.AaveV3XYCSwap;

    error AaveV3XYCSwapZeroLiquidity();
    error AaveV3XYCSwapInsufficientLiquidity();

    function sizeOf(address, address) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 20 + 20;
    }

    function build(address aTokenA, address aTokenB) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(aTokenA, aTokenB)), aTokenA, aTokenB).resolve();
    }

    function build(MemoryPtr ptrStart, address aTokenA, address aTokenB) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(aTokenA).push(aTokenB);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (address aTokenA, address aTokenB) {
        aTokenA = args.at(0).asAddress();
        aTokenB = args.at(20).asAddress();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (address aTokenA, address aTokenB) = parse(args);
        uint256 balanceA = IERC20(aTokenA).balanceOf(ctx.query.maker);
        uint256 balanceB = IERC20(aTokenB).balanceOf(ctx.query.maker);

        if (ctx.query.tokenIn < ctx.query.tokenOut) {
            ctx.swap.balanceIn = balanceA;
            ctx.swap.balanceOut = balanceB;
        } else {
            ctx.swap.balanceIn = balanceB;
            ctx.swap.balanceOut = balanceA;
        }

        if (ctx.swap.balanceIn == 0 || ctx.swap.balanceOut == 0) revert AaveV3XYCSwapZeroLiquidity();

        if (ctx.query.isExactIn) {
            // Floor division favors the maker, as in the standard XYCSwap opcode.
            ctx.swap.amountOut = ctx.swap.amountIn * ctx.swap.balanceOut / (ctx.swap.balanceIn + ctx.swap.amountIn);
        } else {
            if (ctx.swap.amountOut >= ctx.swap.balanceOut) revert AaveV3XYCSwapInsufficientLiquidity();
            // Ceil division favors the maker, as in the standard XYCSwap opcode.
            ctx.swap.amountIn = (ctx.swap.amountOut * ctx.swap.balanceIn).ceilDiv(ctx.swap.balanceOut - ctx.swap.amountOut);
        }
    }
}
