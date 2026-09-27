// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasPoolFixture} from "./SwapGas.t.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev Isolated public ABI measurements. Callbacks are invoked as the real manager; settled
/// end-to-end swaps are separately measured in SwapGas.t.sol. Disabled callbacks must revert.
contract GasHookSurfaceTest is GasPoolFixture {
    function test_gas_CAP() public {
        uint256 value = hook.CAP();
        _report("Hook.CAP");
        assertEq(value, CAP);
    }

    function test_gas_poolManager() public {
        IPoolManager value = hook.poolManager();
        _report("Hook.poolManager");
        assertEq(address(value), address(manager));
    }

    function test_gas_getHookPermissions() public {
        Hooks.Permissions memory value = hook.getHookPermissions();
        _report("Hook.getHookPermissions");
        Hooks.Permissions memory expected;
        expected.afterInitialize = true;
        expected.afterSwap = true;
        assertEq(abi.encode(value), abi.encode(expected));
    }

    function test_gas_status_freshBlock() public {
        (bool active, uint256 remaining, uint256 end) = hook.status(key.toId());
        _report("Hook.status.freshBlock");
        assertTrue(active);
        assertEq(remaining, CAP);
        assertEq(end, 1_086_400);
    }

    function test_gas_status_uninitialized() public {
        (bool active, uint256 remaining, uint256 end) = hook.status(PoolId.wrap(bytes32(uint256(999))));
        _report("Hook.status.uninitialized");
        assertFalse(active);
        assertEq(remaining, CAP);
        assertEq(end, 0);
    }

    function test_gas_afterInitialize() public {
        PoolKey memory second = key;
        second.fee = 500;
        vm.prank(address(manager));
        bytes4 selector = hook.afterInitialize(address(this), second, 1, 0);
        _report("Hook.afterInitialize");
        assertEq(selector, IHooks.afterInitialize.selector);
        (bool active, uint256 remaining, uint256 end) = hook.status(second.toId());
        assertTrue(active);
        assertEq(remaining, CAP);
        assertEq(end, 1_086_400);
    }

    function test_gas_afterSwap_firstBuy() public {
        vm.prank(address(manager));
        (bytes4 selector, int128 hookDelta) = hook.afterSwap(
            address(router), key, SwapParams(true, 100_000 ether, 1), toBalanceDelta(-1 ether, 100_000 ether), ""
        );
        _report("Hook.afterSwap.firstBuy");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0);
        (, uint256 remaining,) = hook.status(key.toId());
        assertEq(remaining, CAP - 100_000 ether);
    }

    function test_gas_beforeInitialize_disabled() public {
        _disabled(abi.encodeCall(IHooks.beforeInitialize, (address(this), key, 1)), "Hook.beforeInitialize.revert");
    }

    function test_gas_beforeAddLiquidity_disabled() public {
        _disabled(
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, ModifyLiquidityParams(-60, 60, 1, 0), "")),
            "Hook.beforeAddLiquidity.revert"
        );
    }

    function test_gas_afterAddLiquidity_disabled() public {
        _disabled(
            abi.encodeCall(
                IHooks.afterAddLiquidity,
                (
                    address(this),
                    key,
                    ModifyLiquidityParams(-60, 60, 1, 0),
                    BalanceDelta.wrap(0),
                    BalanceDelta.wrap(0),
                    ""
                )
            ),
            "Hook.afterAddLiquidity.revert"
        );
    }

    function test_gas_beforeRemoveLiquidity_disabled() public {
        _disabled(
            abi.encodeCall(
                IHooks.beforeRemoveLiquidity, (address(this), key, ModifyLiquidityParams(-60, 60, -1, 0), "")
            ),
            "Hook.beforeRemoveLiquidity.revert"
        );
    }

    function test_gas_afterRemoveLiquidity_disabled() public {
        _disabled(
            abi.encodeCall(
                IHooks.afterRemoveLiquidity,
                (
                    address(this),
                    key,
                    ModifyLiquidityParams(-60, 60, -1, 0),
                    BalanceDelta.wrap(0),
                    BalanceDelta.wrap(0),
                    ""
                )
            ),
            "Hook.afterRemoveLiquidity.revert"
        );
    }

    function test_gas_beforeSwap_disabled() public {
        _disabled(
            abi.encodeCall(IHooks.beforeSwap, (address(this), key, SwapParams(true, -1, 1), "")),
            "Hook.beforeSwap.revert"
        );
    }

    function test_gas_beforeDonate_disabled() public {
        _disabled(abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, "")), "Hook.beforeDonate.revert");
    }

    function test_gas_afterDonate_disabled() public {
        _disabled(abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, "")), "Hook.afterDonate.revert");
    }

    function _disabled(bytes memory data, string memory label) private {
        vm.prank(address(manager));
        (bool ok, bytes memory reason) = address(hook).call(data);
        _report(label);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(BaseHook.HookNotImplemented.selector));
    }
}

contract GasHookUsedStatusTest is GasPoolFixture {
    function _established() internal pure override returns (bool) {
        return true;
    }

    function test_gas_status_usedBlock() public {
        (bool active, uint256 remaining, uint256 end) = hook.status(key.toId());
        _report("Hook.status.usedBlock");
        assertTrue(active);
        assertEq(remaining, CAP - previousOutput);
        assertEq(end, 1_086_400);
    }
}
