# SDK Fixes — Round 2

Follow-up fixes for the `sdk/` TypeScript SDK, from a review of the Round 1
implementation. The Solidity contracts in `src/` are the source of truth and
MUST NOT be modified. Same conventions as Round 1: `QuipSwapError` with codes
from the `QuipSwapErrorCode` union, full TSDoc, bigint everywhere, no new
unsafe casts.

Work through the fixes in order. After all fixes: run `bun run check`,
`bun run test:integration`, and `bun run test:cross-chain` from `sdk/` and do
not report a task complete unless the relevant commands actually passed.

---

## Fix 1 — Document that explicit `opts.gas` disables the pre-submission revert check

With `TxOptions.gas` set, estimation is skipped entirely — and since
`simulateContract` was removed in Round 1, NOTHING checks the call against
chain state before submission beyond the SDK's protocol preflights. A
reverting transaction will then be submitted and burn its gas on-chain.

Doc-only change: extend the `TxOptions.gas` TSDoc in `sdk/src/gas.ts` to
state explicitly: setting `gas` skips estimation AND the multiplier AND the
pre-submission revert check; the protocol preflights still run; use it only
when the gas cost of the call is known and the caller accepts on-chain
revert risk. Mirror one sentence of this into the `prepareTx` stage-1 doc
and the README's write-flow section.

---

## Fix 2 — Wrong-secret hint in the claim lock-state error

A wrong secret derives a DIFFERENT lock, which reads as `Unused` on-chain —
so today the most common claim mistake surfaces as "nothing has been
committed under this lock on this chain", which is accurate but does not
point at the actual cause.

In `verifyClaimState` (`sdk/src/client.ts`), extend the `Unused`-state
cause string to: "nothing has been committed under this lock on this chain
— either the swap was never committed here, or the supplied secret is not
this swap's preimage (a wrong secret derives a different lock)". Also add
the derived lock to the error `details` (it is already in scope) so a
developer can compare it against the expected lock. Update the matching
test assertion if it matches on the message text.

---

## Fix 3 — `reclaimable-from-free` must pick the committed leg's reclaim window

### Problem

In `getSameChainSwapStatus` (`sdk/src/workflows/sameChain.ts`), the
`LockState.Free` branch tests `plan.proposerReclaimWindow` on the
assumption that the committed leg is the proposer's. On the pathological
taker-first-commit path (documented in the `proposer-commit-expired`
status), the `Free` lock holds the TAKER's leg, whose reclaim opens at
`taker.reclaimRelease` — so the status would report
`reclaimable-from-free` as early as `proposer.reclaimRelease`, and the
attempted reclaim would then fail `WINDOW_VIOLATED` /
`WindowViolated`.

### Changes

1. The report already fetches `proposerPosted` and `takerPosted`. In the
   `Free` branch, select the committed leg's window:

   ```ts
   const freeLegReclaimWindow =
     takerPosted && !proposerPosted ? plan.takerReclaimWindow : plan.proposerReclaimWindow
   ```

   and use `freeLegReclaimWindow` for the `reclaimable-from-free` test.
   Keep the normal case (proposer committed) behavior identical.
2. While in the `Free` branch, the `awaiting-taker-window` /
   `awaiting-taker-commit` / `half-committed-expired` labels also assume
   the proposer committed; when `takerPosted && !proposerPosted` they are
   misleading. Do NOT invent new statuses for the pathological path —
   instead, in that sub-case map directly to either
   `reclaimable-from-free` (window open) or `half-committed-expired`
   (window not yet open; the swap can never complete since the proposer's
   commit window has necessarily closed). Document the mapping in the
   status TSDoc.
3. Unit test (pure, with a mocked client or extracted pure status
   function): a `Free` lock with `takerPosted=true, proposerPosted=false`
   reports `half-committed-expired` before `taker.reclaimRelease` and
   `reclaimable-from-free` at/after it — never `awaiting-taker-commit`,
   and never `reclaimable-from-free` before `taker.reclaimRelease`.

---

## Verification items (no code unless something is missing)

1. Confirm Round 1's section 4.6 documentation sync actually happened:
   `sdk/README.md`'s write-flow section must describe
   estimate-with-buffer (not simulateContract), and the prompt/spec
   markdown at the repository root must no longer mandate
   `simulateContract` before every write. Apply the sync now if it was
   missed.
2. Run the full suites and report real output: `bun run check`,
   `bun run test:integration`, `bun run test:cross-chain`, plus
   `forge test` at the repository root to confirm the contracts remain
   untouched and green.
