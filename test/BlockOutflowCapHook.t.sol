// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolFixture} from "./utils/PoolFixture.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract BlockOutflowCapHookTest is PoolFixture {
    using StateLibrary for IPoolManager;

    event Outflow(PoolId indexed poolId, uint256 blockNumber, uint256 amount, uint256 usedInBlock);

    function test_permissionsMatchAddressAndOnlyTwoCallbacks() public view {
        Hooks.Permissions memory expected;
        expected.afterInitialize = true;
        expected.afterSwap = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), 0x1040);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.CAP(), token.totalSupply() / 400);
    }

    function test_launchRehearsalOneSidedSeedFirstBuyThenSellAndUnwind() public {
        assertEq(seedDelta.amount0(), 0, "seed must cost no ETH");
        assertLt(seedDelta.amount1(), 0);
        assertEq(address(manager).balance, 0);
        assertEq(manager.getLiquidity(id), 0, "seed is below opening price");

        uint256 beforeToken = token.balanceOf(address(this));
        uint256 beforeETH = address(this).balance;
        BalanceDelta bought = _swap(key, true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1, "");
        uint256 output = uint256(uint128(bought.amount1()));
        uint256 cost = uint256(-int256(bought.amount0()));
        assertGt(output, 0);
        assertGt(manager.getLiquidity(id), 0);
        assertEq(token.balanceOf(address(this)), beforeToken + output);
        assertEq(address(this).balance, beforeETH - cost);
        assertEq(address(manager).balance, cost);
        assertEq(_remaining(id), CAP - output);

        BalanceDelta sold = _swap(key, false, -int256(output / 2), TickMath.MAX_SQRT_PRICE - 1, "");
        assertGt(sold.amount0(), 0);
        assertLt(sold.amount1(), 0);
        assertEq(_remaining(id), CAP - output);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(LOWER, UPPER, -LIQUIDITY, 0), "");
        assertEq(manager.getLiquidity(id), 0);
        assertEq(_remaining(id), CAP - output);
        _assertConservation();
    }

    function test_exactCapPassesOneMoreWeiRevertsAtomically() public {
        _buy(key, 1_000_000 ether);
        _buy(key, 1_500_000 ether);
        assertEq(_remaining(id), 0);
        (uint160 priceBefore,,,) = manager.getSlot0(id);
        uint128 liquidityBefore = manager.getLiquidity(id);
        uint256 userToken = token.balanceOf(address(this));
        uint256 managerToken = token.balanceOf(address(manager));
        uint256 userETH = address(this).balance;
        uint256 managerETH = address(manager).balance;

        vm.expectRevert(_capRevert(CAP + 1));
        _buy(key, 1);
        assertEq(_remaining(id), 0);
        (uint160 priceAfter,,,) = manager.getSlot0(id);
        assertEq(priceAfter, priceBefore);
        assertEq(manager.getLiquidity(id), liquidityBefore);
        assertEq(token.balanceOf(address(this)), userToken);
        assertEq(token.balanceOf(address(manager)), managerToken);
        assertEq(address(this).balance, userETH);
        assertEq(address(manager).balance, managerETH);
    }

    function test_singleOversizedBuyRevertsAndLeavesFullAllowance() public {
        vm.expectRevert(_capRevert(CAP + 1));
        _buy(key, CAP + 1);
        assertEq(_remaining(id), CAP);
        assertEq(address(manager).balance, 0);
    }

    function test_newBlockResetsWithoutTimestampChange() public {
        _buy(key, CAP);
        vm.roll(block.number + 1);
        assertEq(_remaining(id), CAP);
        vm.expectEmit(true, false, false, true, address(hook));
        emit Outflow(id, block.number, CAP, CAP);
        _buy(key, CAP);
        assertEq(_remaining(id), 0);
    }

    function test_timestampAdvanceDoesNotResetSameBlock() public {
        _buy(key, CAP);
        vm.warp(block.timestamp + 60);
        vm.expectRevert(_capRevert(CAP + 1));
        _buy(key, 1);
    }

    function test_exactInputCountsActualCurrency1Output() public {
        BalanceDelta delta = _swap(key, true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1, "");
        uint256 output = uint256(uint128(delta.amount1()));
        assertGt(output, 1 ether, "output must differ from input units");
        assertEq(_remaining(id), CAP - output);
        _buy(key, CAP - output);
        vm.expectRevert(_capRevert(CAP + 1));
        _buy(key, 1);
    }

    function test_exactOutputCountsActualOutputAndEmitsCumulativeTotals() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit Outflow(id, block.number, 10 ether, 10 ether);
        BalanceDelta delta = _buy(key, 10 ether);
        assertEq(delta.amount1(), 10 ether);
        vm.expectEmit(true, false, false, true, address(hook));
        emit Outflow(id, block.number, 20 ether, 30 ether);
        _buy(key, 20 ether);
        assertEq(_remaining(id), CAP - 30 ether);
    }

    function test_partialExactOutputAtPriceLimitCountsOnlyFilledOutput() public {
        // Requested output is over CAP, but the limit stops the real swap after about 300k BCAP.
        BalanceDelta delta = _swap(key, true, int256(2 * CAP), TickMath.getSqrtPriceAtTick(138_060), "");
        uint256 actual = uint256(uint128(delta.amount1()));
        assertGt(actual, 0);
        assertLt(actual, CAP);
        assertEq(_remaining(id), CAP - actual);
    }

    function test_sellsExactInputAndOutputNeverCountOrRefundAllowance() public {
        _buy(key, CAP);
        vm.recordLogs();
        _swap(key, false, -int256(100 ether), TickMath.MAX_SQRT_PRICE - 1, "");
        _swap(key, false, int256(0.01 ether), TickMath.MAX_SQRT_PRICE - 1, "");
        _assertNoOutflow(vm.getRecordedLogs());
        assertEq(_remaining(id), 0);
        vm.expectRevert(_capRevert(CAP + 1));
        _buy(key, 1);
    }

    function test_liquidityRemovalAndDonationsDoNotCount() public {
        _buy(key, CAP);
        vm.recordLogs();
        donateRouter.donate{value: 1 ether}(key, 1 ether, 10 ether, "");
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(LOWER, UPPER, -LIQUIDITY / 2, 0), "");
        _assertNoOutflow(vm.getRecordedLogs());
        assertEq(_remaining(id), 0);
        vm.expectRevert(_capRevert(CAP + 1));
        _buy(key, 1);
    }

    function test_capEndsAtBoundaryAndAccountingFreezes() public {
        (bool active, uint256 remaining, uint256 end) = hook.status(id);
        assertTrue(active);
        assertEq(remaining, CAP);
        assertEq(end, block.timestamp + 86_400);
        vm.warp(end - 1);
        _buy(key, CAP);
        vm.expectRevert(_capRevert(CAP + 1));
        _buy(key, 1);

        vm.warp(end);
        (active,,) = hook.status(id);
        assertFalse(active);
        vm.recordLogs();
        _buy(key, 2 * CAP);
        _assertNoOutflow(vm.getRecordedLogs());
        assertEq(_remaining(id), 0, "expired same-block accounting is frozen");
        vm.warp(end + 1);
        vm.roll(block.number + 1);
        assertEq(_remaining(id), CAP);
        _buy(key, 2 * CAP);
        assertEq(_remaining(id), CAP);
    }

    function test_twoPoolsHaveIndependentAllowanceAndExpiry() public {
        _buy(key, CAP);
        vm.warp(block.timestamp + 100);
        PoolKey memory second = key;
        second.fee = 500;
        manager.initialize(second, TickMath.getSqrtPriceAtTick(138_180));
        _seed(second);
        PoolId secondId = second.toId();
        assertEq(_remaining(secondId), CAP);
        _buy(second, CAP);
        assertEq(_remaining(secondId), 0);
        assertEq(_remaining(id), 0);
        (,, uint256 firstEnd) = hook.status(id);
        (,, uint256 secondEnd) = hook.status(secondId);
        assertEq(secondEnd, firstEnd + 100);
        vm.warp(firstEnd);
        _buy(key, CAP + 1);
        vm.expectRevert(_capRevert(CAP + 1));
        _buy(second, 1);
    }

    function test_uninitializedStatusAndRepeatedInitialization() public {
        (bool active, uint256 remaining, uint256 end) = hook.status(PoolId.wrap(bytes32(uint256(999))));
        assertFalse(active);
        assertEq(remaining, CAP);
        assertEq(end, 0);
        (,, uint256 originalEnd) = hook.status(id);
        vm.warp(block.timestamp + 100);
        vm.expectRevert();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(138_180));
        (,, end) = hook.status(id);
        assertEq(end, originalEnd);
    }

    function test_enabledCallbacksRejectDirectCallers() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, 1, 0);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, 1, 1), toBalanceDelta(-1, 1), "");
        assertEq(_remaining(id), CAP);
    }

    function test_hookDataAndRouterIdentityGiveNoPrivilege() public {
        _swap(key, true, int256(CAP), TickMath.MIN_SQRT_PRICE + 1, abi.encode(address(hook)));
        vm.expectRevert(_capRevert(CAP + 1));
        _swap(key, true, 1, TickMath.MIN_SQRT_PRICE + 1, hex"deadbeef");
    }

    function test_zeroOutputAtPriceLimitDoesNotEmitOrCount() public {
        // Price crosses only the empty range above the one-sided position.
        vm.recordLogs();
        BalanceDelta delta = _swap(key, true, -int256(1 ether), TickMath.getSqrtPriceAtTick(138_150), "");
        assertEq(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);
        assertEq(_remaining(id), CAP);
        _assertNoOutflow(vm.getRecordedLogs());
    }

    function testFuzz_splitBuysReachCapAndNextWeiFails(uint256 first) public {
        first = bound(first, 1, CAP - 1);
        _buy(key, first);
        assertEq(_remaining(id), CAP - first);
        _buy(key, CAP - first);
        assertEq(_remaining(id), 0);
        vm.expectRevert(_capRevert(CAP + 1));
        _buy(key, 1);
        _assertConservation();
    }

    function _assertNoOutflow(Vm.Log[] memory logs) internal view {
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(hook), "unexpected hook event");
        }
    }

    function _assertConservation() internal view {
        assertEq(token.balanceOf(address(this)) + token.balanceOf(address(manager)), token.totalSupply());
        assertEq(address(this).balance + address(manager).balance, 10_000 ether);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(swapRouter).balance, 0);
        assertEq(token.balanceOf(address(swapRouter)), 0);
    }
}
