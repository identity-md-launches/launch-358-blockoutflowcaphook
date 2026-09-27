// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Blockcap} from "../../src/Blockcap.sol";

contract GasBlockcapTest is Test {
    Blockcap internal token;
    address internal constant SPENDER = address(0xA11CE);
    address internal constant RECIPIENT = address(0xB0B);

    function setUp() public {
        token = new Blockcap();
        token.approve(SPENDER, 100 ether);
    }

    function _report(string memory label) internal {
        emit log_named_uint(label, vm.lastCallGas().gasTotalUsed);
    }

    function test_gas_INITIAL_SUPPLY() public {
        uint256 value = token.INITIAL_SUPPLY();
        _report("Blockcap.INITIAL_SUPPLY");
        assertEq(value, 1_000_000_000 ether);
    }

    function test_gas_name() public {
        string memory value = token.name();
        _report("Blockcap.name");
        assertEq(value, "Blockcap");
    }

    function test_gas_symbol() public {
        string memory value = token.symbol();
        _report("Blockcap.symbol");
        assertEq(value, "BCAP");
    }

    function test_gas_decimals() public {
        uint8 value = token.decimals();
        _report("Blockcap.decimals");
        assertEq(value, 18);
    }

    function test_gas_totalSupply() public {
        uint256 value = token.totalSupply();
        _report("Blockcap.totalSupply");
        assertEq(value, 1_000_000_000 ether);
    }

    function test_gas_balanceOf() public {
        uint256 value = token.balanceOf(address(this));
        _report("Blockcap.balanceOf");
        assertEq(value, 1_000_000_000 ether);
    }

    function test_gas_allowance() public {
        uint256 value = token.allowance(address(this), SPENDER);
        _report("Blockcap.allowance");
        assertEq(value, 100 ether);
    }

    function test_gas_approve_newSpender() public {
        bool ok = token.approve(RECIPIENT, 100 ether);
        _report("Blockcap.approve.newSpender");
        assertTrue(ok);
        assertEq(token.allowance(address(this), RECIPIENT), 100 ether);
    }

    function test_gas_approve_existingSpender() public {
        bool ok = token.approve(SPENDER, 60 ether);
        _report("Blockcap.approve.existingSpender");
        assertTrue(ok);
        assertEq(token.allowance(address(this), SPENDER), 60 ether);
    }

    function test_gas_transfer() public {
        bool ok = token.transfer(RECIPIENT, 60 ether);
        _report("Blockcap.transfer");
        assertTrue(ok);
        assertEq(token.balanceOf(RECIPIENT), 60 ether);
    }

    function test_gas_transferFrom() public {
        vm.prank(SPENDER);
        bool ok = token.transferFrom(address(this), RECIPIENT, 60 ether);
        _report("Blockcap.transferFrom");
        assertTrue(ok);
        assertEq(token.balanceOf(RECIPIENT), 60 ether);
        assertEq(token.allowance(address(this), SPENDER), 40 ether);
    }
}
