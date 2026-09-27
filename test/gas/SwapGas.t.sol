// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Blockcap} from "../../src/Blockcap.sol";
import {BlockOutflowCapHook} from "../../src/BlockOutflowCapHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";

/// @dev Setup is a separate EVM call: earlier buys are committed before the measured test begins.
/// This avoids measuring a warmed, dirty-storage second call as if it were a later transaction.
/// No RPC, etched implementation, changed permissions, or alternate PoolManager is used.
abstract contract GasPoolFixture is Test {
    uint256 internal constant CAP = 2_500_000 ether;
    address internal constant TRADER = address(0xBEEF);
    IPoolManager internal manager;
    Blockcap internal token;
    BlockOutflowCapHook internal hook;
    PoolSwapTest internal router;
    PoolKey internal key;
    uint256 internal previousOutput;

    function _hooked() internal pure virtual returns (bool) {
        return true;
    }

    function _established() internal pure virtual returns (bool) {
        return false;
    }

    function _nextBlock() internal pure virtual returns (bool) {
        return false;
    }

    function _expired() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public virtual {
        vm.warp(1_000_000);
        vm.roll(100);
        vm.deal(TRADER, 100 ether);
        // Load build artifacts to keep the benchmark's own runtime below EIP-170.
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        token = Blockcap(deployCode("Blockcap.sol:Blockcap"));
        router = PoolSwapTest(deployCode("PoolSwapTest.sol:PoolSwapTest", abi.encode(manager)));
        PoolModifyLiquidityTest liquidityRouter = PoolModifyLiquidityTest(
            deployCode("PoolModifyLiquidityTest.sol:PoolModifyLiquidityTest", abi.encode(manager))
        );
        if (_hooked()) hook = _deployHook();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        token.approve(address(liquidityRouter), type(uint256).max);
        vm.prank(TRADER);
        token.approve(address(router), type(uint256).max);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(138_180));
        BalanceDelta seed =
            liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(120_000, 138_120, 100_000 ether, 0), "");
        assertEq(seed.amount0(), 0, "seed must contain no ETH");
        assertLt(seed.amount1(), 0);
        assertEq(address(manager).balance, 0);
        if (_established()) {
            BalanceDelta bought = _swap(true, -int256(1 ether));
            previousOutput = uint256(uint128(bought.amount1()));
            assertGt(previousOutput, 100_000 ether);
            assertLt(previousOutput, CAP);
        }
        if (_nextBlock()) vm.roll(101);
        if (_expired()) vm.warp(1_086_400);
    }

    function _deployHook() private returns (BlockOutflowCapHook) {
        bytes memory code =
            abi.encodePacked(vm.getCode("BlockOutflowCapHook.sol:BlockOutflowCapHook"), abi.encode(manager));
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, hash)))));
            if (!HookFlags.matches(predicted, HookFlags.BLOCK_OUTFLOW_CAP)) continue;
            address deployed;
            assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
            assertEq(deployed, predicted);
            assertGt(deployed.code.length, 0);
            return BlockOutflowCapHook(deployed);
        }
        revert("hook salt search exhausted");
    }

    function _swap(bool buy, int256 amount) internal returns (BalanceDelta) {
        vm.prank(TRADER);
        return router.swap{value: buy ? 1 ether : 0}(
            key,
            SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _report(string memory label) internal {
        // Capture before assertions or further contract calls. With --isolate, Foundry includes
        // intrinsic/calldata gas for state-changing top-level calls; STATICCALLs are frame-only.
        // With --no-isolate all values are frame execution gas. The report records both modes.
        emit log_named_uint(label, vm.lastCallGas().gasTotalUsed);
    }

    function _check(BalanceDelta delta, bool buy) internal view {
        if (buy) {
            assertLt(delta.amount0(), 0);
            assertGt(delta.amount1(), 0);
        } else {
            assertGt(delta.amount0(), 0);
            assertEq(delta.amount1(), -int128(100_000 ether));
        }
        uint256 output = buy ? uint256(uint128(delta.amount1())) : 0;
        uint256 balance = buy ? previousOutput + output : previousOutput - 100_000 ether;
        assertEq(token.balanceOf(TRADER), balance, "swap must settle to the trader");
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
        if (_hooked()) {
            (bool active, uint256 remaining, uint256 end) = hook.status(key.toId());
            uint256 used = _nextBlock() ? 0 : previousOutput;
            if (!_expired()) used += output;
            assertEq(active, !_expired());
            assertEq(remaining, CAP - used, "only active buys consume allowance");
            assertEq(end, 1_086_400);
        }
    }
}

abstract contract BuyGasFixture is GasPoolFixture {
    function test_gas_swap_buy_exactInput() public {
        BalanceDelta delta = _swap(true, -int256(1 ether));
        _report("swap.buy.exactInput");
        assertEq(delta.amount0(), -int128(1 ether), "input must be fully filled");
        _check(delta, true);
    }

    function test_gas_swap_buy_exactOutput() public {
        BalanceDelta delta = _swap(true, int256(100_000 ether));
        _report("swap.buy.exactOutput");
        assertEq(delta.amount1(), int128(100_000 ether), "output must be fully filled");
        _check(delta, true);
    }
}

contract GasHookLaunchSwapTest is BuyGasFixture {}

contract GasNoHookLaunchSwapTest is BuyGasFixture {
    function _hooked() internal pure override returns (bool) {
        return false;
    }
}

contract GasHookLaterSwapTest is BuyGasFixture {
    function _established() internal pure override returns (bool) {
        return true;
    }

    function test_gas_swap_sell_exactInput() public {
        BalanceDelta delta = _swap(false, -int256(100_000 ether));
        _report("swap.sell.exactInput");
        _check(delta, false);
    }
}

contract GasNoHookLaterSwapTest is GasHookLaterSwapTest {
    function _hooked() internal pure override returns (bool) {
        return false;
    }
}

contract GasHookNewBlockSwapTest is BuyGasFixture {
    function _established() internal pure override returns (bool) {
        return true;
    }

    function _nextBlock() internal pure override returns (bool) {
        return true;
    }
}

contract GasNoHookNewBlockSwapTest is GasHookNewBlockSwapTest {
    function _hooked() internal pure override returns (bool) {
        return false;
    }
}

contract GasHookExpiredSwapTest is GasHookLaterSwapTest {
    function _expired() internal pure override returns (bool) {
        return true;
    }
}

contract GasNoHookExpiredSwapTest is GasHookExpiredSwapTest {
    function _hooked() internal pure override returns (bool) {
        return false;
    }
}
