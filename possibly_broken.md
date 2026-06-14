# Possibly Broken — E2E Review Findings

End-to-end correctness review of the `sdk/` TypeScript SDK. **Nothing in this
document has been fixed** — it is a findings log only, per the request.

## Status at time of review

All automated suites pass, so none of these are caught by the current tests:

| Suite | Result |
| --- | --- |
| `bun run check` (typecheck + unit + mocked + build) | 143 tests pass, build OK |
| `bun run test:integration` (Anvil + differential) | 44 tests pass |
| `bun run test:cross-chain` (two Anvils) | 5 tests pass |

Build/publish surface is healthy: `viem` is correctly externalized (not
bundled), `dist/` contains `index.js` + `index.d.ts` + sourcemap,
`package.json` `main`/`types`/`exports` resolve, `files: ["dist"]`,
`bun.lock` present, no `TODO`/`FIXME` in `src/`. The findings below are
latent issues, not regressions.

---

## Finding 1 — Event decoders do not filter by the Omnibus contract address (MEDIUM)

**Where:**
- `sdk/src/receipts.ts:87-89` — `waitForOmnibusReceipt` passes the whole
  `receipt.logs` array to the decoders.
- `sdk/src/events.ts:132,161,209` — `decodeCommitmentEvents` /
  `decodeClaimEvents` / `decodeReclaimedEvents` call
  `parseEventLogs({abi: omnibusAbi, eventName, logs, strict: true})`.
- `sdk/src/events.ts:191` — `extractRevealedSecret` is built on
  `decodeClaimEvents`, so it inherits the gap.

**What's wrong:** `parseEventLogs` matches logs by event-signature topic hash
and ABI shape only — it does **not** filter by the emitting contract's
`address`. `waitForOmnibusReceipt` and the three `decode*Events` helpers
therefore decode ANY log in the transaction whose topic0 matches
`Commitment` / `Claim` / `Reclaimed`, regardless of which contract emitted
it. A second contract in the same transaction that emits a same-signature
event (`Claim(address,bytes32,bytes32)`, `Reclaimed(address,bytes32,address)`,
`Commitment(bytes32,(...),address)`) would be returned as a genuine Omnibus
event — feeding spoofed `secret` / `lock` / `party` values to callers and to
`extractRevealedSecret`.

**Why it matters:** `claim`/`reclaim` are permissionless and can be batched
by relayers/aggregators/smart-contract wallets, so multiple protocols'
events legitimately co-occur in one transaction. `extractRevealedSecret` is
documented as the mechanism a cross-chain taker uses to learn the secret —
decoding a foreign `Claim` would mislead that flow. Severity is held to
MEDIUM (not HIGH) because standard ERC-20/721/1155 token logs use different
signatures (no accidental collision), the lock topic is `keccak256(secret)`
(hard to collide), and triggering it requires another contract in the same
tx deliberately emitting a colliding event.

**Note on inconsistency:** the historical-query path already does this
correctly — `getOmnibusLogs` (`events.ts:290`) and `watchClaimEvents`
(`events.ts:319`) both scope `getLogs`/`watchContractEvent` to
`address: args.address`. Only the receipt-decode path is unscoped.
`waitForOmnibusReceipt` has no `address` parameter today, so closing the gap
would need an API addition (pass the Omnibus address and filter
`log.address === address`).

---

## Finding 2 — `buildFeeOverrides` does not enforce `gasPrice` ⊻ EIP-1559 exclusivity (LOW–MEDIUM)

**Where:** `sdk/src/gas.ts:121-127` (`buildFeeOverrides`), surfacing in
`sdk/src/client.ts:634` (`submitWrite` catch).

**What's wrong:** `TxOptions` documents `maxFeePerGas`/`maxPriorityFeePerGas`
as "exclusive with `gasPrice`", but `buildFeeOverrides` forwards whatever the
caller set with no exclusivity check. If a caller passes both `gasPrice` and
`maxFeePerGas`, all three fields reach `writeContract`, and viem throws a
fee-conflict (`Eip1559FeesNotSupportedError` / cannot-mix) error.

**Why it matters:** That conflict error is thrown at the `writeContract`
step, so it (a) only surfaces AFTER a wasted `estimateContractGas`
round-trip, and (b) falls through `submitWrite`'s catch to
`wrapContractError`, getting mislabeled `CONTRACT_REVERT` — a misleading code
for what is actually a caller options-validation error. No wrong on-chain
result; it's a footgun + misleading error. A guard in `buildFeeOverrides` (or
`prepareTx`) throwing a dedicated validation error before estimation would be
the clean fix.

---

## Finding 3 — Cross-chain reaction-buffer docs/error claim it is a single "adjacent gap" (LOW, doc accuracy)

**Where:** `sdk/src/workflows/crossChain.ts:97-98` (docstring), `:167-169`
(the `INSUFFICIENT_BUFFER` error message), against the loop at `:157-174`.

**What's wrong:** The interleaved schedule order is
`proposer.commit < taker.commit < proposer.claim < taker.claim <
proposer.reclaimRelease < taker.reclaim`. The documented reaction buffer is
`proposer.reclaimRelease - proposer.claimDeadline` — but those two timestamps
are **not adjacent**: `taker.claimDeadline` sits between them. The validation
loop only checks consecutive pairs, so the reaction buffer is actually the
**sum of two separately-checked gaps**
(`taker.claimDeadline - proposer.claimDeadline` plus
`proposer.reclaimRelease - taker.claimDeadline`) and is therefore always
`>= 2 * minimumBufferSeconds`. The docstring ("Every gap between adjacent
timestamps … including the reaction buffer") and the error message ("Every
adjacent gap — especially the taker's post-reveal reaction buffer
(proposer.reclaimRelease - proposer.claimDeadline)") both imply the reaction
buffer is itself one of the adjacent pairs being checked.

**Why it matters:** Behavior is **safe** (the buffer is over-satisfied, never
under), so this is not a logic bug — but by this project's own standard ("an
inaccurate docstring is a bug") the wording misrepresents what is enforced. A
reader could believe the reaction buffer is bounded at exactly
`minimumBufferSeconds` when it is effectively bounded at `2x`. Fix is
wording-only (or, if the intent was to bound the reaction buffer directly,
add an explicit `reactionBufferSeconds >= minimumBufferSeconds` check).

---

## Finding 4 — Explicit `opts.gas` skips the only pre-submission revert check (LOW, by-design but undocumented consequence)

**Where:** `sdk/src/gas.ts:251-253` — when `opts.gas` is set, estimation is
skipped entirely.

**What's wrong / consequence:** `estimateContractGas` is the SDK's
pre-submission revert check (it replaced `simulateContract`). When a caller
passes an explicit `gas`, that check is bypassed, so a call that would revert
on-chain is no longer caught before submission — it is sent and reverts,
burning gas, and is only observed later via `waitForOmnibusReceipt`
(`TRANSACTION_REVERTED`). The protocol/lock-state preflights still run, so
most logical errors are still caught; what is lost is the contract-level
revert simulation. This is consistent with the documented "explicit gas
bypasses estimation and the multiplier" behavior, but the **revert-check loss
is not called out** in the `TxOptions.gas` docs. Informational — flag so a
caller setting `gas` understands they forgo the revert preflight.

---

## Finding 5 — Window / fee / lock-state preflights are inherently TOCTOU (INFORMATIONAL)

**Where:** `sdk/src/client.ts` — `chainTimestamp()` (reads the latest block)
feeding `validateCommitWindow`/`validateClaimWindow`/`validateReclaimWindow`
(`:726`, `:802`, `:849`); commit's fee re-read (`:759`); the `verify*State`
lock-state reads.

**What's wrong / consequence:** All preflights evaluate against the latest
block's state, but the transaction mines later against a higher
`block.timestamp` and possibly mutated state (fee changed by owner, lock
advanced by a racing party). A commit/claim validated as "in window" can
still revert on-chain near a window boundary; a commit can still hit
`IncorrectNativeAmountReceived` if the fee changes after the re-read. This is
an unavoidable property of any off-chain preflight and is already documented
in spirit ("SDK validation does not replace contract enforcement"), so it is
listed only for completeness — not a defect. `estimateContractGas` shares the
same latest-state evaluation, so it does not close the gap either.

---

## Not problems (checked and confirmed correct)

- Hashing (`digestTerms`/`digestTermsCanonically`/`generateLock`), window
  math (`enforceWithin` half-open with exclusive upper), `validateTerms`,
  `validateTermPairing`, `proposedBy`, and asset builders/`validateAsset` all
  match the Solidity source exactly (also proven by the differential suite).
- `applyGasMultiplier` bigint scaling is exact across `[1.0, 2.0]`;
  `resolveGasMultiplier` clamping and non-finite handling are correct.
- The balance-preflight-before-estimation reorder (gas_fix / gas_update2) is
  correct and the docstrings now match the implementation; the send-time
  `InsufficientFundsError → BALANCE_TOO_LOW` mapping in `submitWrite` is
  correct.
- ERC-20 allowance aggregation, ERC-721/1155 approval checks, and
  address-casing comparisons in `approvals.ts` are correct.
- `resolveDeployment`, `generateSecret`/`secretToPair` (no secret leakage),
  the same-chain status state machine, and all `index.ts` exports
  resolve/are complete.
- viem externalized; package `exports`/`types`/`files` resolve.
