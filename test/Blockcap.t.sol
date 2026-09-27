// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Blockcap} from "../src/Blockcap.sol";

contract TokenFactoryFixture {
    function deploy() external returns (Blockcap) {
        return new Blockcap();
    }
}

contract BlockcapTest is Test {
    Blockcap internal token;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new Blockcap();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Blockcap");
        assertEq(token.symbol(), "BCAP");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_factoryReceivesWholeSupplyWithoutArguments() public {
        TokenFactoryFixture factory = new TokenFactoryFixture();
        Blockcap deployed = factory.deploy();
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    function testFuzz_transferConservesSupplyWithoutTax(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, amount);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromConsumesAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), ALICE, 100 ether);
        assertTrue(token.approve(ALICE, 100 ether));
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 60 ether));
        assertEq(token.allowance(address(this), ALICE), 40 ether);
        assertEq(token.balanceOf(BOB), 60 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 60 ether);
    }

    function test_infiniteAllowanceRemainsInfiniteAndCanBeRevoked() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 100 ether);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        token.approve(ALICE, 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(address(this), BOB, 1);
    }

    function test_insufficientAllowanceAndBalanceRevertWithoutChangingState() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(address(this), ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroAddressTransfersAndApprovalsRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_selfTransferAndZeroTransferPreserveBalances() public {
        token.transfer(address(this), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_noMintBurnOwnerOrUpgradeEntryPointsEvenForDeployer() public {
        string[13] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, type(uint128).max);
            (bool deployerCall,) = address(token).call(data);
            assertFalse(deployerCall);
            vm.prank(ALICE);
            (bool attackerCall,) = address(token).call(data);
            assertFalse(attackerCall);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(ALICE), 0);
        }
    }
}
