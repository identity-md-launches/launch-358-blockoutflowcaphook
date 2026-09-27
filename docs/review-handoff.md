# Contract review handoff

The source-producing assignment implements Blockcap and BlockOutflowCapHook and exports their ABIs.
This document records implementation checks for the independent reviewer; it is not an independent
security review, audit, launch approval, manifest or service attestation.

## Properties covered locally

`test/BlockOutflowCapHook.t.sol` uses a real v4-core PoolManager and the upstream settlement routers:

- Exact permission/address agreement (`0x1040`) and immutable manager identity.
- One-sided BCAP initialization and seeding with zero ETH, followed by a first exact-input buy,
  a sell, complete liquidity removal, and asset conservation.
- Several buys totaling exactly CAP; one additional wei and a single oversized buy revert with
  the exact nested cap error. Rejection preserves balances, pool price, liquidity and allowance.
- Exact-input and exact-output accounting, cumulative events, partial fills at a price limit,
  and zero-output swaps in the empty price range.
- Resets on block number changes only; expiry one second before, at, and after capEndsAt.
- Sells of both order types never count or restore allowance; donations and liquidity removal
  remain possible even with exhausted allowance.
- Separate pools retain independent caps and start/end times. Reinitialization fails.
- Unauthorized direct calls to **both** enabled callbacks fail, including afterSwap, which is not
  exercised by the supplied callback-refusal floor. Arbitrary hookData provides no privilege.
- 256 fuzzed splits of CAP check exact totals, conservation and the next-wei rejection.

`test/BlockOutflowCapHook.invariant.t.sol` generates buys, sells, block changes and time changes against
the real manager. A separate model tracks actual settled output. Both accounting and conservation
invariants run 64 sequences of 32 calls each. Expected cap failures are decoded, and unexpected
failures are rejected. Swaps already at the extreme price limit are excluded in that direction
because PoolManager rejects a limit equal to the current price.

`test/Blockcap.t.sol` covers fixed supply/metadata, factory ownership of the full initial supply,
transfers, finite/infinite allowances and revocation, self/zero transfers, invalid receivers and
spenders, insufficient balance/allowance, and rejection of common mint/burn/admin/upgrade selectors.
Transfer amounts are fuzzed over the entire supply. `test/RuntimeSafety.t.sol` scans real deployed
token and hook bytecode for SELFDESTRUCT, DELEGATECALL and CALLCODE, skipping PUSH operands, and
checks the EIP-170 runtime size limit.

## Review focus and release handoff

The hook's only storage writes are initialization and active positive buy accounting. Neither
callback performs external calls. All external hook callbacks inherit `onlyPoolManager`. No callback
can request custom accounting: all return-delta bits are false and the afterSwap return delta is zero.
PoolManager and upstream routers perform settlement; the hook never handles tokens or ETH.

The rule intentionally allows arbitrary attached pools and restricts only each pool's currency1 buy
outflow. It does not restrict transfers, liquidity withdrawals, other pools or wallets. For a foreign
currency1, the constant is still expressed in raw units, not normalized decimals. BCAP is standard,
non-rebasing and has no transfer fees; support for nonstandard tokens in third-party pools is not
promised. The launch does not rely on an oracle, user identity or any hookData payload.

Before release, the independent review assignment inspects accepted source and the separately
generated launch.json without editing implementation files. Services verify chain ID, PoolManager
identity, factory constructor encoding, CREATE2 deployer/salt/address flags, source/bytecode/ABI
agreement, and the final native-ETH/BCAP key. They must rehearse actual factory initialization,
one-sided liquidity, buys and sells against current Sepolia state. The local manager rehearsal is
not a fork or evidence that the deployed Sepolia factory has already been exercised.

Policy decisions and signed artifact linkage are service responsibilities. This handoff cannot
assert that publication, attestation, admission, deployment, independent review or the frontend
have completed. No funded-wallet transactions are included.
