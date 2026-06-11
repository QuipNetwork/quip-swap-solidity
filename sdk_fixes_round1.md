# SDK Fixes — Round 1

Tasks for the `sdk/` TypeScript SDK in this repository. The Solidity contracts
in `src/` are the source of truth and MUST NOT be modified. Follow the
existing codebase conventions exactly: `QuipSwapError` with codes from the
`QuipSwapErrorCode` union, full TSDoc on every export (`@param`, `@returns`,
`@throws`, `@see` references to the Solidity being mirrored, `@example` on
primary entry points), bigint everywhere, no unsafe casts, no secret logging.

Work through the fixes in order. After all fixes: run `bun run check`,
`bun run test:integration`, and `bun run test:cross-chain` from `sdk/` and do
not report a task complete unless the relevant commands actually passed.

---

## Fix 1 — Lock-state preflight for claim, reclaim, and commit

### Problem

`Omnibus.posted` and `Omnibus.termsHash` are NEVER cleared when a lock is
spent. The current `verifyPostedState` preflight in `sdk/src/client.ts`
checks only `termsHash` + `posted`, so:

- claiming an already-settled (Spent) lock passes every SDK preflight and
  dies at simulation as a generic `CONTRACT_REVERT` (`InvalidLockState`);
- reclaiming a Spent or Unused lock likewise only fails at simulation
  (`InvalidLockAdvancement`);
- a duplicate same-side commit only fails at simulation
  (`TermsAlreadyPosted`).

The contract requirements (verify in `src/Omnibus.sol`, do not trust this
file): `claim` requires `lockState == Committed`
(`_enforceCommittedLock`); `reclaim` requires `Free` or `Committed`
(`_advanceLockTo` permits Free→Spent and Committed→Spent only); a second
same-chain `commit` on a `Free` lock requires the canonical termsHash to
match and the committing side to not already be posted.

### Changes

1. Add two codes to the `QuipSwapErrorCode` union in `sdk/src/errors.ts`,
   with the same documentation standard as the existing codes:
   - `'INVALID_LOCK_STATE'` — the lock's on-chain state does not permit the
     attempted action (wraps the preflight equivalent of the contract's
     `InvalidLockState` / `InvalidLockAdvancement`).
   - `'TERMS_ALREADY_POSTED'` — the committing side's terms digest is
     already posted for this lock (preflight equivalent of
     `TermsAlreadyPosted`).

2. Extend the on-chain-state preflight in `client.ts` so the `lockState`
   read joins the existing `Promise.all` in `verifyPostedState` (rename or
   restructure the helper as needed — one round of parallel reads, no
   sequential extra latency):
   - **claim**: require `lockState === LockState.Committed`; otherwise
     throw `INVALID_LOCK_STATE` with `details: {lock, lockState, required:
     'Committed'}` and a message that names the likely cause per state
     (Unused → nothing committed under this lock on this chain; Free →
     the counterparty has not committed yet; Spent → already claimed or
     reclaimed).
   - **reclaim**: require `lockState === Free || lockState === Committed`;
     otherwise throw `INVALID_LOCK_STATE` with the actual state in details.
   - These checks live under the existing `verifyOnChainState` flag
     (default `true`), same as termsHash/posted — the flag's meaning stays
     "extra on-chain reads before simulation". With the flag off, behavior
     is unchanged (simulation still catches everything).

3. Add the symmetric preflight to **commit**: add
   `verifyOnChainState?: boolean` (default `true`) to `CommitArgs`. When
   enabled, read `lockState(lock)` (and, if the state is `Free`, also
   `termsHash(lock)` and `posted(lock, digestTerms(party))` in the same
   parallel batch):
   - `Spent` or `Committed` → `INVALID_LOCK_STATE` (no commit can ever
     advance from these states).
   - `Free` → require `termsHash(lock)` to equal
     `digestTermsCanonically(party, counterparty)` (throw the existing
     `TERMS_NOT_ON_CHAIN` on mismatch, matching the claim preflight's
     convention) and require `posted(lock, digestTerms(party))` to be
     `false` (throw `TERMS_ALREADY_POSTED` otherwise — the second
     same-chain commit must post the OTHER side).
   - `Unused` → no extra requirement.

4. Update the TSDoc on `commit`/`claim`/`reclaim` (preflight step lists and
   `@throws`) and on `ClaimArgs`/`ReclaimArgs`/`CommitArgs`.

5. Tests:
   - unit/mocked: each new preflight path produces its precise code before
     any `simulateContract` call; `verifyOnChainState: false` skips the
     reads and falls through to simulation.
   - integration (Anvil): claim on a Spent lock → `INVALID_LOCK_STATE`
     preflight (not `CONTRACT_REVERT`); reclaim on an Unused lock →
     `INVALID_LOCK_STATE`; duplicate same-side commit →
     `TERMS_ALREADY_POSTED` preflight; second commit with mismatched
     counterparty terms → `TERMS_NOT_ON_CHAIN` preflight; all of the same
     scenarios with `verifyOnChainState: false` still revert correctly at
     simulation with the decoded contract error name.

---

## Fix 2 — Explicitly SKIPPED: party-side `posted` check in same-chain claim

Do NOT add a preflight read of `posted(lock, digestTerms(party))` to claim.
Rationale (encode this as a short comment in the claim preflight, so a
future contributor doesn't "complete" the check):

- The contract's party-side `_enforcePosted` in `claim` executes only when
  `party.chainId == block.chainid`. In a cross-chain claim the claimant's
  own leg is on the other chain by definition, so the branch is unreachable
  cross-chain — it is purely the same-chain dual-settle path.
- For same-chain swaps, `Committed` is reachable only via
  Unused→Free→Committed, where the second commit must match the same
  canonical `termsHash` (`TermsMismatch` guard) and must post the
  not-yet-posted side (`TermsAlreadyPosted` guard). Therefore
  `Committed` (same-chain) provably implies BOTH sides are posted.
- With Fix 1's `lockState === Committed` preflight in place, a party-side
  posted read would verify an implied condition: it can never fire. (Its
  marginal cost inside the parallel read batch is small — the reason to
  skip it is zero information content, not the request cost.) The contract
  keeps its own check as defense-in-depth; the preflight does not need to
  duplicate implied conditions.
- Note the existing `posted(lock, counterpartyDigest)` read is, strictly,
  also implied by `Committed` + a matching `termsHash` (the termsHash
  binds the lock to this exact pair, commits are enforced local, and the
  claimed leg is local). KEEP it anyway: it costs nothing extra in latency
  inside the `Promise.all`, and because the three reads are not atomic it
  localizes which value disagrees under an RPC race or a violated
  invariant, instead of leaving a confusing simulation revert.

---

## Fix 3 — Docstring correction: `proposer-commit-expired` is not "the swap is dead"

In `sdk/src/workflows/sameChain.ts`, the `SameChainSwapStatus` variant
`'proposer-commit-expired'` is documented as "the swap is dead". That is
slightly stronger than the contract: with the lock still `Unused` and the
proposer's window closed, the contract WILL still accept a taker-first
commit in `[proposer.commitmentDeadline, taker.commitmentDeadline)` —
`Omnibus.commit` only checks the window, not that the proposer actually
committed (the contract comment says the committer "MUST ensure the
commitment from the counterparty has taken effect"; that duty is the
committer's, not the contract's). Such a commit moves the lock
Unused→Free with the taker's side posted, is economically pointless (the
proposer can no longer commit, so the lock can never reach Committed), and
strands the taker's assets until `taker.reclaimRelease` (reclaim from
Free).

Reword the docstring to state exactly that: the swap can no longer complete,
but the contract still accepts a (pointless, self-harming) taker-first
commit; SDK consumers should treat this status as terminal and must not
commit into it. Keep the status name unchanged. No logic changes.

---

## Fix 4 — Gas estimation with a safety multiplier (replaces simulateContract)

This must match our organization's wallet-SDK conventions, specified
completely below — do not invent different semantics.

### 4.1 New module: `sdk/src/gas.ts`

Export these constants:

```ts
export const DEFAULT_GAS_MULTIPLIER = 1.2  // 20% safety margin
export const MIN_GAS_MULTIPLIER = 1.0      // floor; below 1.0 risks OOG
export const MAX_GAS_MULTIPLIER = 2.0      // ceiling; caps misconfiguration
```

Export a `TxOptions` interface accepted by every write method (`commit`,
`claim`, `reclaim`, and all four `admin.*` writes). All fields optional:

```ts
interface TxOptions {
  gas?: bigint              // explicit gas limit; when set, SKIP estimation
                            // and the multiplier entirely
  gasMultiplier?: number    // gas = floor(estimate * multiplier);
                            // default DEFAULT_GAS_MULTIPLIER; clamped to
                            // [MIN_GAS_MULTIPLIER, MAX_GAS_MULTIPLIER];
                            // non-finite values fall back to MIN (no buffer)
  maxFeePerGas?: bigint          // EIP-1559 ceiling (exclusive with gasPrice)
  maxPriorityFeePerGas?: bigint  // EIP-1559 tip (exclusive with gasPrice)
  gasPrice?: bigint              // legacy pricing for non-1559 chains
  nonce?: number                 // pin nonce; default = viem fetches it
  skipPreflightChecks?: boolean  // skips the BALANCE preflight ONLY; the
                                 // protocol preflights (windows, pairing,
                                 // quip-wallet, chain id, lock state)
                                 // ALWAYS run
}
```

Multiplier math must be bigint-safe and deterministic — never multiply a
bigint by a float. Resolve the multiplier (default + clamp), round to
exactly 3 decimal places by scaling:

```ts
const scaled = Math.round(multiplier * 1000)
gas = (estimate * BigInt(scaled)) / 1000n
```

Export `applyGasMultiplier(estimate, opts)` and
`resolveGasMultiplier(opts)` separately so tests and callers can inspect
the resolved value.

Forward fee fields selectively: build a `FeeOverrides` object containing
ONLY the fee fields the caller explicitly set, so viem's automatic fee
pricing keeps working for everything unset. Never pass `undefined` fee
fields through.

### 4.2 `prepareTx`

Export an async `prepareTx({publicClient, contractParams, totalValue,
opts})` returning `{gas, fees, nonce?}` ready to spread into
`writeContract`. `contractParams` is `{address, abi, functionName, args,
value?, account}`. `totalValue` is the total native value the sender must
pay — for commit exactly `totalNative(party) + commitmentFee` (already
computed by the client); `0n` for claim/reclaim/admin.

Stage order, each stage with its own typed error:

1. **Gas estimation**: if `opts.gas` is set, use it verbatim (no
   multiplier). Otherwise call
   `publicClient.estimateContractGas(contractParams)`.
   - `estimateContractGas` executes the call node-side, so contract
     reverts surface here: wrap them with the existing
     `wrapContractError` (decoded error name + cause preserved). This
     call REPLACES `simulateContract` as the pre-submission revert
     check; remove the simulate step from every write.
   - If estimation fails for a non-revert reason (network, bad params),
     throw code `'GAS_ESTIMATION_FAILED'` with the original error as
     `cause`.
2. **Multiplier**: apply to the estimate (skip when `opts.gas` provided).
3. **Balance preflight** (unless `skipPreflightChecks`): performed AFTER
   estimation so it can require `totalValue + gas * maxFeePerGas` — use
   the resolved buffered gas, and the caller-supplied `maxFeePerGas` if
   set, else fees from `publicClient.estimateFeesPerGas()`; if no fee
   data is obtainable, fall back to checking `totalValue` alone. Throw
   code `'BALANCE_TOO_LOW'` carrying `{required, balance}` in details.

### 4.3 Client integration

In every write method in `client.ts`, run the existing pure protocol
preflights FIRST (structural validation, pairing, window, chain-id,
quip-wallet for commit, Fix 1's lock-state checks) so failures produce
specific protocol errors — only then call `prepareTx`, then
`writeContract` with the prepared `gas`/`fees`/`nonce` spread in plus the
function args/value/account. Public write signatures gain an optional
final `opts?: TxOptions` parameter (`commit(args, opts?)` etc.; admin
methods too).

Document in the client docstrings: unused gas is refunded, so the 1.2x
buffer costs nothing at execution; its purpose is preventing out-of-gas
failures from state drift between estimation and inclusion — which
matters in this protocol because writes happen inside closing time
windows and an OOG'd claim near a window boundary may be unrecoverable.

### 4.4 New error codes

Add `'BALANCE_TOO_LOW'` and `'GAS_ESTIMATION_FAILED'` to the
`QuipSwapErrorCode` union, documented to the existing standard.

### 4.5 Tests

Unit (pure):
- default multiplier 1.2: `100_000n -> 120_000n`
- clamping: `0.5 -> 1.0`; `5 -> 2.0`; `NaN`/`Infinity` -> `1.0`
- 3-decimal honoring: `1.137` on `1_000_000n -> 1_137_000n`
- bigint math exact for large estimates (no float round-trip drift)
- explicit `opts.gas` bypasses estimation and multiplier
- fee overrides: only explicitly-set fields forwarded

Mocked-client:
- `estimateContractGas` called with the exact contract params (function,
  args, value, account)
- `writeContract` receives the buffered gas value
- revert during estimation produces the decoded typed error
  (`CONTRACT_REVERT` with `contractErrorName`), not a generic failure;
  non-revert estimation failure produces `GAS_ESTIMATION_FAILED`
- `skipPreflightChecks` skips only the balance check, never the protocol
  preflights

Integration (Anvil):
- a real commit/claim/reclaim succeeds end-to-end with the default
  multiplier
- balance preflight rejects an underfunded sender before any tx is sent
- a revert condition (e.g. commit outside its window with
  `verifyOnChainState: false`) surfaces through the estimation path with
  the correct decoded contract error name

Update any existing tests that asserted simulate-before-write to assert
the estimate-before-write flow instead.

### 4.6 Documentation sync

- Update `sdk/README.md`'s write-flow section (simulate → estimate+buffer).
- If the prompt/spec markdown at the repository root describes
  `simulateContract` as the mandated write flow, update that section to
  describe the estimate-based flow, so future sessions don't "fix" the
  code back.
