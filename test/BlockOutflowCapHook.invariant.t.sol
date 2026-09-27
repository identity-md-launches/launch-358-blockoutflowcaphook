// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolFixture} from "./utils/PoolFixture.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BlockOutflowCapHook} from "../src/BlockOutflowCapHook.sol";
import {Blockcap} from "../src/Blockcap.sol";

/// @dev Independent accounting model driven by settled swap output and arbitrary block/time steps.
contract CapHandler is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant CAP = 2_500_000 ether;
    BlockOutflowCapHook public immutable hook;
    PoolSwapTest public immutable router;
    PoolKey internal key;
    uint256 public immutable end;
    uint256 public modelBlock;
    uint256 public modelUsed;

    constructor(BlockOutflowCapHook hook_, PoolSwapTest router_, PoolKey memory key_, Blockcap token) {
        hook = hook_;
        router = router_;
        key = key_;
        (,, end) = hook_.status(key_.toId());
        token.approve(address(router_), type(uint256).max);
    }

    function buy(uint256 requested) external {
        (uint160 price,,,) = hook.poolManager().getSlot0(key.toId());
        if (price == TickMath.MIN_SQRT_PRICE + 1) return;
        requested = bound(requested, 1, CAP + 1);
        try router.swap{value: 100 ether}(
            key,
            SwapParams(true, int256(requested), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (
            BalanceDelta delta
        ) {
            uint256 actual = uint256(uint128(delta.amount1()));
            assertLe(actual, requested);
            if (block.timestamp < end && actual > 0) {
                if (modelBlock != block.number) modelUsed = 0;
                modelBlock = block.number;
                modelUsed += actual;
                assertLe(modelUsed, CAP);
            }
        } catch (bytes memory reason) {
            // Every accepted failure must be a cap rejection, including PoolManager's wrapper.
            assertLt(block.timestamp, end);
            assertEq(bytes4(reason), CustomRevert.WrappedError.selector);
            (address target, bytes4 selector, bytes memory inner, bytes memory details) =
                abi.decode(_withoutSelector(reason), (address, bytes4, bytes, bytes));
            assertEq(target, address(hook));
            assertEq(selector, IHooks.afterSwap.selector);
            assertEq(details, abi.encodeWithSelector(Hooks.HookCallFailed.selector));
            assertEq(bytes4(inner), BlockOutflowCapHook.BlockCapExceeded.selector);
            (uint256 attempted, uint256 cap) = abi.decode(_withoutSelector(inner), (uint256, uint256));
            assertEq(cap, CAP);
            assertGt(attempted, CAP);
            assertLe(attempted, (modelBlock == block.number ? modelUsed : 0) + requested);
        }
    }

    function sell(uint256 input) external {
        (uint160 price,,,) = hook.poolManager().getSlot0(key.toId());
        if (price == TickMath.MAX_SQRT_PRICE - 1) return;
        input = bound(input, 1, CAP);
        router.swap(
            key,
            SwapParams(false, -int256(input), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function advance(uint256 blocks, uint256 seconds_) external {
        vm.roll(block.number + bound(blocks, 0, 3));
        vm.warp(block.timestamp + bound(seconds_, 0, 12 hours));
    }

    function _withoutSelector(bytes memory data) private pure returns (bytes memory result) {
        result = new bytes(data.length - 4);
        for (uint256 i; i < result.length; ++i) {
            result[i] = data[i + 4];
        }
    }

    receive() external payable {}
}

contract BlockOutflowCapInvariantTest is PoolFixture {
    CapHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CapHandler(hook, swapRouter, key, token);
        assertTrue(token.transfer(address(handler), 100_000_000 ether));
        vm.deal(address(handler), 10_000 ether);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = CapHandler.buy.selector;
        selectors[1] = CapHandler.sell.selector;
        selectors[2] = CapHandler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_statusMatchesSettledOutputModel() public view {
        (bool active, uint256 remaining, uint256 end) = hook.status(id);
        assertEq(end, handler.end());
        assertEq(active, block.timestamp < end);
        assertLe(handler.modelUsed(), CAP);
        assertEq(remaining, handler.modelBlock() == block.number ? CAP - handler.modelUsed() : CAP);
    }

    function invariant_assetsAndSupplyAreConserved() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(handler)) + token.balanceOf(address(manager)),
            token.totalSupply()
        );
        assertEq(address(this).balance + address(handler).balance + address(manager).balance, 20_000 ether);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(swapRouter)), 0);
        assertEq(address(swapRouter).balance, 0);
    }
}
