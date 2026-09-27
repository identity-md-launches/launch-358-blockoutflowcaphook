// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Limits currency1 buy outflow per pool and block during the first day of each pool.
/// @dev The launch pool is native ETH / BCAP. Any other pool may attach this hook; the same raw-unit
/// cap then applies to that pool's currency1. There is no token whitelist, admin, fee or hook delta.
contract BlockOutflowCapHook is BaseHook {
    uint256 public constant CAP = 2_500_000 ether;

    struct PoolCap {
        uint256 capEndsAt;
        uint256 lastBlock;
        uint256 used;
    }

    mapping(PoolId poolId => PoolCap) private _caps;

    /// @param used The attempted cumulative output, including the swap that is being rejected.
    /// @param cap The maximum cumulative output in a single block.
    error BlockCapExceeded(uint256 used, uint256 cap);

    event Outflow(PoolId indexed poolId, uint256 blockNumber, uint256 amount, uint256 usedInBlock);

    constructor(IPoolManager poolManager_) BaseHook(poolManager_) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.afterSwap = true;
    }

    /// @notice Uninitialized pools are inactive. Expiry is exclusive: active only before capEndsAt.
    /// @dev remainingThisBlock reports accounting headroom; only enforce it when active is true.
    /// After expiry, accounting is frozen. A new block always reports CAP as the remaining amount.
    function status(PoolId poolId) external view returns (bool active, uint256 remainingThisBlock, uint256 capEndsAt) {
        PoolCap storage state = _caps[poolId];
        capEndsAt = state.capEndsAt;
        active = block.timestamp < capEndsAt;
        remainingThisBlock = state.lastBlock == block.number ? CAP - state.used : CAP;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        // PoolManager permits initialization only once for a given PoolId.
        _caps[key.toId()].capEndsAt = block.timestamp + 1 days;
        return IHooks.afterInitialize.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        PoolCap storage state = _caps[poolId];
        int128 output = delta.amount1();
        if (block.timestamp < state.capEndsAt && params.zeroForOne && output > 0) {
            // A strictly positive int128 fits in uint128; widening to uint256 preserves its value.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(uint128(output));
            uint256 used = (state.lastBlock == block.number ? state.used : 0) + amount;
            if (used > CAP) revert BlockCapExceeded(used, CAP);

            state.lastBlock = block.number;
            state.used = used;
            emit Outflow(poolId, block.number, amount, used);
        }
        return (IHooks.afterSwap.selector, 0);
    }
}
