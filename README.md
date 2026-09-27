# Blockcap contracts

Blockcap (BCAP) is a fixed-supply ERC-20. `BlockOutflowCapHook` limits currency1 paid out by buys to
2,500,000 BCAP per pool per block during the first 86,400 seconds after pool initialization.
This repository delivers the contract implementation, local tests, pinned dependencies and ABI exports
for the approved Sepolia contract stage. The separate manifest and independent review assignments,
followed by service publication, attestation, admission, factory deployment and the live frontend, use
these artifacts. No deployment or independent review is claimed here.

## Build and check

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abis.py --check
```

The compiler is pinned to Solidity **0.8.26**, targeting **Cancun**, with optimizer runs **200**,
`bytecode_hash = "none"` and CBOR metadata disabled. The last setting also makes the bytecode opcode
checks independent of metadata. FFI and filesystem cheatcode permissions are disabled. Tests do not
use environment variables, network access, forks or external services. Test state is recreated for
each test and works with parallel execution.

All imported dependencies are ordinary vendored files under `lib/`; there are no submodules or package
installation steps. An installed Foundry and the pinned compiler are the only build prerequisites.
`docs/dependencies.json` records upstream commits and the SHA-256 of every vendored file, including
licenses. These are minimal import closures, not complete upstream checkouts:

| Dependency | Revision |
| --- | --- |
| [Uniswap v4-core](https://github.com/Uniswap/v4-core/tree/a7cf038cd568801a79a9b4cf92cd5b52c95c8585) | `a7cf038cd568801a79a9b4cf92cd5b52c95c8585` |
| [Uniswap v4-periphery](https://github.com/Uniswap/v4-periphery/tree/444c526b77d804590f0d7bc5a481af5a3277c952) | `444c526b77d804590f0d7bc5a481af5a3277c952` |
| [OpenZeppelin Contracts v5.3.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/e4f70216d759d8e6a64144a9e1f7bbeed78e7079) | `e4f70216d759d8e6a64144a9e1f7bbeed78e7079` |
| [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` |
| [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `4b47a19038b798b4a33d9749d25e570443520647` |

The periphery revision retains the required `BaseHook` and pins the selected core revision. Vendored
source retains its upstream license, including v4-core's BUSL-1.1 license; application source is MIT.

## Contracts and behavior

`src/Blockcap.sol:Blockcap` extends OpenZeppelin ERC20. Its argument-free constructor mints exactly
`1_000_000_000 * 10**18` units to `msg.sender`, so a factory deployment gives the supply to the factory.
Name: `Blockcap`; symbol: `BCAP`; decimals: `18`. Standard transfers and approvals apply. There is no
public mint, burn, owner, pause, transfer tax or upgrade mechanism.

`src/BlockOutflowCapHook.sol:BlockOutflowCapHook` extends v4-periphery `BaseHook`. Its constructor takes
exactly one `IPoolManager`. It enables only `afterInitialize` and `afterSwap`, and both inherited entry
points reject callers other than that immutable manager. All return-delta permissions are false;
`afterSwap` returns zero delta. The hook neither takes fees nor holds or settles swap funds.

The launch pool is currency0 native ETH, currency1 BCAP, static LP fee `3000` and tick spacing `60`.
Uniswap v4 uses negative `amountSpecified` for exact input and positive for exact output. A
`zeroForOne` swap is a buy. The hook counts the **positive currency1 component of the actual
`BalanceDelta`**, so partial fills and both order types use the amount actually delivered. It never
uses the requested input/output as the amount to count.

Each `PoolId` has its own end time and block counter:

- Initialization records `block.timestamp + 86_400`; deployment time is irrelevant. The real
  PoolManager prevents reinitializing an existing pool.
- Before that time, buys may cumulatively deliver at most `CAP = 2_500_000 * 10**18` per block.
  An attempted total above CAP reverts `BlockCapExceeded(attemptedTotal, CAP)`, rolling back the
  entire swap. There is no clamping and no partial execution caused by the cap.
- A new block starts a fresh allowance, even if its timestamp is unchanged. Advancing timestamp
  alone does not reset the block counter.
- Sells do not consume or restore allowance. Liquidity deposits, withdrawals and donations do not
  invoke cap accounting. Zero-output swaps do not consume allowance or emit an Outflow event.
- At exactly `capEndsAt`, and afterwards, buys are unlimited by this hook. Accounting freezes and
  no further Outflow events are emitted for that pool.

Any pool may attach this hook. There is no token or fee whitelist: the same **raw-unit currency1**
limit applies independently to other pools, regardless of their decimals. This is a per-pool cap,
not a token-wide or per-wallet restriction. Other pools and liquidity withdrawals can move BCAP
without consuming the launch pool's allowance.

The hook ignores `sender` and `hookData` because it neither credits nor identifies swappers. Routers
have no special privileges. **hookData is unauthenticated**; including an address in it conveys no
authorization. The hook has no external calls in its accounting logic, unbounded loops, or admin
paths. See [the review handoff](docs/review-handoff.md) for tested properties and remaining service work.

## ABI and frontend integration

Committed compiler exports:

- [Blockcap ABI](docs/abi/Blockcap.json)
- [BlockOutflowCapHook ABI](docs/abi/BlockOutflowCapHook.json)

Regenerate them after source changes with `python3 scripts/export_abis.py`.

| Interface | Meaning |
| --- | --- |
| `CAP() -> uint256` | `2500000000000000000000000` raw units |
| `poolManager() -> address` | Immutable callback authority |
| `getHookPermissions()` | Only `afterInitialize` and `afterSwap` are true |
| `status(bytes32 poolId) -> (bool active, uint256 remainingThisBlock, uint256 capEndsAt)` | Current accounting state |
| `Outflow(bytes32 indexed poolId, uint256 blockNumber, uint256 amount, uint256 usedInBlock)` | A successful positive buy output during the capped day |
| `BlockCapExceeded(uint256 used, uint256 cap)` | `used` includes the rejected buy |

`PoolId` is `keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))`. For an uninitialized
pool, status is `(false, CAP, 0)`. If the last counted block differs from the current block, remaining
is CAP. Otherwise it is CAP minus the stored total, including when the cap has just expired. Consumers
must use **active** to decide whether remaining is a restriction; an expired pool can report zero
remaining in the last counted block while accepting unlimited buys.

The future page (`lab-per-block-cap-hook`) should read status at a known block, display
`max(capEndsAt - block.timestamp, 0)`, and group Outflow logs by indexed pool ID and block number.
Logs describe only the capped day; for later trade history use PoolManager Swap events. Refresh on
new blocks and reconcile chain reorganizations. Quotes and remaining allowance can become stale:
other buys may consume the cap before inclusion. Warn only when active and quoted **actual output**
exceeds remaining. A warning cannot guarantee execution. The PoolManager wraps callback errors in
`WrappedError`; decode its nested reason for `BlockCapExceeded`.

The approved downstream Sepolia interfaces are PoolSwapTest
`0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe`, StateView
`0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C`, and V4Quoter
`0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227`. These are workflow-supplied parameters, not live RPC
verification results. Swaps must forward `hookData` and `sqrtPriceLimitX96`. The hook does not add
slippage protection; frontend/services must validate the router's execution behavior and chosen price
limit. The website is a later static-export stage with `dist/index.html`, not part of this deliverable.

## Deployment parameters and responsibilities

| Parameter | Approved value |
| --- | --- |
| Network | Sepolia, chain ID `11155111` |
| Launch type | `univ4_hook` |
| Token artifact | `src/Blockcap.sol:Blockcap`; no constructor arguments |
| Hook artifact | `src/BlockOutflowCapHook.sol:BlockOutflowCapHook` |
| Hook constructor argument | `IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543)` |
| Hook flags | `afterInitialize`, `afterSwap`; mask `0x1040` / decimal `4160` |
| Address validation | `uint160(hookAddress) & 0x3fff == 0x1040` |
| Native currency | currency0 = `address(0)` |
| Token currency | currency1 = deployed BCAP address |
| Pool parameters | fee `3000`, tickSpacing `60` |
| Supply and distribution origin | `1_000_000_000e18`, minted entirely to the deploying factory |
| Cap parameters | `2_500_000e18`, 86,400 seconds; immutable source constants |

Services must mine a CREATE2 salt using the actual factory/deployer address, the final compiled hook
creation code and its ABI-encoded PoolManager argument. Constructor address validation is enabled
in production and tests. `HookMiner` is vendored for this purpose; the tests mine their own matching
addresses and never bypass validation or replace hook bytecode. A salt mined for a test contract or a
different manager is not a production deployment salt.

The factory address, allocations, opening price, seed tick range/liquidity, mined hook address and
CREATE2 salt are service inputs still to be supplied. Local rehearsal uses opening tick `138180`,
position ticks `[120000, 138120]`, and liquidity `100000e18` as representative test parameters. The
position is entirely below the opening price, so it deposits only BCAP and the first buy starts with
zero ETH in the PoolManager. These fixture values are not a launch allocation proposal.

The manifest assignment owns `launch.json`. It must agree with these concrete artifacts, constructor,
supply and permission flags. Services own source publication, policy resolution, signed artifact
linkage, attestation, admission, deployment and the live-pool frontend handoff. Missing future service
artifacts are not source implementation failures. Concrete source, constructor, policy or authorization
conflicts still belong in independent review findings. Services must verify Sepolia runtime identities,
rehearse against the actual factory and live PoolManager, and supply final pool coordinates to the
frontend. Operators monitor deployment and Outflow events; there is no owner who can pause, extend,
reset or change this cap after deployment.
