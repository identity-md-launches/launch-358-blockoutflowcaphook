// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {Blockcap} from "../../src/Blockcap.sol";
import {BlockOutflowCapHook} from "../../src/BlockOutflowCapHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";

abstract contract PoolFixture is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant CAP = 2_500_000 ether;
    int24 internal constant LOWER = 120_000;
    int24 internal constant UPPER = 138_120;
    int256 internal constant LIQUIDITY = 100_000 ether;

    IPoolManager internal manager;
    Blockcap internal token;
    BlockOutflowCapHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolDonateTest internal donateRouter;
    PoolKey internal key;
    PoolId internal id;
    BalanceDelta internal seedDelta;

    function setUp() public virtual {
        vm.warp(1_000_000);
        vm.roll(100);
        vm.deal(address(this), 10_000 ether);
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new Blockcap();
        hook = _deployHook(manager);
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        donateRouter = new PoolDonateTest(manager);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);
        token.approve(address(donateRouter), type(uint256).max);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        id = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(138_180));
        seedDelta = _seed(key);
    }

    function _deployHook(IPoolManager poolManager) internal returns (BlockOutflowCapHook deployed) {
        bytes32 codeHash = keccak256(abi.encodePacked(type(BlockOutflowCapHook).creationCode, abi.encode(poolManager)));
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, codeHash)))));
            if (HookFlags.matches(predicted, HookFlags.BLOCK_OUTFLOW_CAP)) {
                deployed = new BlockOutflowCapHook{salt: salt}(poolManager);
                assertEq(address(deployed), predicted);
                return deployed;
            }
        }
        revert("no matching salt");
    }

    function _seed(PoolKey memory poolKey) internal returns (BalanceDelta) {
        return liquidityRouter.modifyLiquidity(poolKey, ModifyLiquidityParams(LOWER, UPPER, LIQUIDITY, 0), "");
    }

    function _buy(PoolKey memory poolKey, uint256 output) internal returns (BalanceDelta) {
        return _swap(poolKey, true, int256(output), TickMath.MIN_SQRT_PRICE + 1, "");
    }

    function _swap(PoolKey memory poolKey, bool buy, int256 amount, uint160 limit, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap{value: buy ? 100 ether : 0}(
            poolKey, SwapParams(buy, amount, limit), PoolSwapTest.TestSettings(false, false), hookData
        );
    }

    function _remaining(PoolId poolId) internal view returns (uint256 remaining) {
        (, remaining,) = hook.status(poolId);
    }

    function _capRevert(uint256 used) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(BlockOutflowCapHook.BlockCapExceeded.selector, used, CAP),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    receive() external payable {}
}
