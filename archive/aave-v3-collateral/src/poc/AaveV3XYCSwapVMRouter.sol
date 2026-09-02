// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import { SwapVM } from "../SwapVM.sol";
import { Opcodes } from "../opcodes/Opcodes.sol";
import { Context } from "../libs/VM.sol";
import { Opcode, OpcodeOps } from "../libs/OpcodeList.sol";
import { AaveV3XYCSwap } from "./AaveV3XYCSwap.sol";

/// @notice POC router which adds the Aave-backed XYCSwap instruction.
/// @dev A production deployment may register extensions differently. Keeping it
///      in this router proves that the Aave leg remains invisible to traders.
contract AaveV3XYCSwapVMRouter is Simulator, SwapVM, Opcodes {
    using OpcodeOps for Opcode;

    constructor(address aqua, address weth, address owner, string memory name, string memory version)
        SwapVM(aqua, weth, owner, name, version)
    { }

    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        if (opcode == AaveV3XYCSwap.opcode.asU8()) AaveV3XYCSwap.exec(ctx, args);
        else _runOpcode(ctx, opcode, args);
    }
}
