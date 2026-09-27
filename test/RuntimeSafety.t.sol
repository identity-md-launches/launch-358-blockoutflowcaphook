// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolFixture} from "./utils/PoolFixture.sol";

/// @dev Mirrors the supplied opcode floor without depending on environment variables or artifacts.
contract RuntimeSafetyTest is PoolFixture {
    function test_tokenAndHookHaveNoRuntimeEscapeHatches() public view {
        _checkRuntime(address(token).code);
        _checkRuntime(address(hook).code);
    }

    function _checkRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
            assertTrue(op != 0xff, "SELFDESTRUCT");
        }
    }
}
