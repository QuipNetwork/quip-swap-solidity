# Feature — Holistic Functional Smoke Test (`bun run smoke`)

Add a single end-to-end smoke test that drives BOTH a same-chain and a
cross-chain swap to completion, THROUGH the workflow layer, against two real
Anvil nodes — a fast "is the whole stack on fire?" gate distinct from the
exhaustive integration suites. The Solidity contracts in `src/` are the
source of truth and MUST NOT be modified.

Locked scope decisions (do not expand):
- **Two Anvil nodes** — one same-chain swap on node A, one cross-chain swap
  spanning A and B.
- **Own runner + `bun run smoke` script** — NOT a vitest file, NOT folded
  into the integration runner. It is a standalone executable script that
  starts/stops its own Anvils and exits non-zero on any failure.
- **Fail fast** — stop at the FIRST broken step, print exactly which step
  failed and the error, exit non-zero immediately. Do not continue.
- **Must exercise the workflow layer** (`planSameChainSwap`,
  `getSameChainSwapStatus`, `planCrossChainSwap`/`validateCrossChainSchedule`,
  `verifyRemoteCommitment`) — not just the client. This is the point of the
  test: those functions, especially `getSameChainSwapStatus`, have little or
  no end-to-end coverage today.

A smoke test proves the layers COMPOSE and the happy path works at all. It
is deliberately shallow on edge cases (the integration suites own those) and
broad on "does the real flow run." Keep it readable as a narrated walkthrough.

After implementation: run `bun run smoke` and confirm it passes (exit 0); do
not report complete otherwise.

---

## Files

- `sdk/scripts/smoke.ts` — the runner (process orchestration + the flow).
- `package.json` — add `"smoke": "<bun/tsx invocation> scripts/smoke.ts"`
  matching how the existing integration runner script is invoked (mirror its
  command shape).
- Reuse, do NOT duplicate: the existing test helpers for connecting a chain,
  deploying the fixture (QuipFactoryMock + Omnibus + mock tokens), artifact
  loading, time control, and actor/wallet setup
  (`sdk/test/helpers/chain.ts`, `fixtures.ts`). If a helper is test-only and
  not importable from a script, lift the needed piece into a shared module
  rather than copy-pasting. Prefer importing the SDK from `src/` (pre-build)
  so the smoke test runs without a build step, consistent with the
  integration suite.

## Runner responsibilities (process lifecycle)

1. Pick two free ports; start two `anvil` instances (chain IDs 31337 and
   31338). Wait until each RPC answers.
2. `forge build` first if artifacts may be stale (mirror the integration
   runner's behavior).
3. On node A: deploy QuipFactoryMock, Omnibus(owner, factory), and the mock
   tokens; register the committing accounts as quip wallets. On node B:
   deploy the same set (its own QuipFactoryMock + Omnibus + tokens; register
   accounts).
4. Run the flow (below). On the FIRST failure: print `SMOKE FAILED at step
   N: <description>` plus the error, tear down BOTH anvils, exit 1.
5. On success: print a concise per-step `ok` log and `SMOKE PASSED`, tear
   down both anvils, exit 0.
6. Teardown (kill both anvil child processes) MUST run on every exit path —
   success, failure, and uncaught exception — so no orphan processes leak.
   Wrap the whole flow in try/finally.

Each "step" is numbered and labeled; fail-fast reports the label. Use a tiny
`step(n, label, async fn)` wrapper that logs `ok`/throws with context.

## Flow part 1 — same-chain swap THROUGH the workflow layer (node A)

The goal is to use the workflow functions to drive and OBSERVE the swap, not
hand-rolled client calls in isolation. Concretely:

1. Build Alice (proposer) and Bob (taker) terms with a strictly interleaved
   schedule derived from node A's current block timestamp; Alice offers
   native ETH, Bob offers ERC-20 (reuse the integration fixtures' schedule
   shape). Generate the secret + lock via the SDK.
2. `const plan = planSameChainSwap(aliceTerms, bobTerms)` — assert it returns
   with Alice as proposer (`plan.proposerTerms` is Alice's) and that
   `plan.canonicalDigest` is non-zero. This exercises role normalization.
3. Assert `getSameChainSwapStatus(clientA, lock, plan).status ===
   'awaiting-proposer-commit'` at the proposer-commit anchor.
4. Approve (via `planApprovals`/`submitApproval`) and `clientA.commit(...)`
   the proposer leg. Assert lockState transitions to `Free` AND that
   `getSameChainSwapStatus` now reports `'awaiting-taker-window'`.
5. Advance node A time past the proposer commitment deadline. Assert status
   is now `'awaiting-taker-commit'`.
6. Approve + commit the taker leg. Assert lockState `Committed` and status
   `'awaiting-claim-window'` or `'claimable'` depending on the anchor —
   advance into the claim window and assert `'claimable'`.
7. `clientA.claim(secret, ...)`. Assert lockState `Spent`, status
   `'settled'`, both legs' assets reached the correct recipients (Bob's
   tokens → Alice's recipient; Alice's ETH → Bob's recipient), and the
   `Claim` event's revealed secret equals the original.

The assertions on `getSameChainSwapStatus` at each phase are the heart of
this part — they are what nothing else tests end-to-end. Hit at least:
`awaiting-proposer-commit`, `awaiting-taker-window`, `awaiting-taker-commit`,
`claimable`, `settled`.

## Flow part 2 — cross-chain swap THROUGH the workflow layer (nodes A + B)

Alice = proposer + secret holder, leg on node A (native ETH). Bob = taker,
leg on node B (ERC-20). One strictly interleaved six-timestamp schedule
shared by both legs.

1. Build the two terms (Alice.chainId = A, Bob.chainId = B). Validate with
   the cross-chain planner/validator: call `validateCrossChainSchedule`
   (and `planCrossChainSwap` if it exists) with an explicit
   `minimumBufferSeconds` matching the schedule's gaps; assert it ACCEPTS.
   Also assert it REJECTS a role-inverted copy (secret holder as taker) —
   one negative assertion, because role assignment is the safety crux.
2. Approve + `clientA.commit` Alice's leg on node A. Assert node A lock
   `Committed`.
3. Call `verifyRemoteCommitment(clientA, ...)` (the mandatory off-chain
   check) and assert it reports committed/posted/termsHash-match true — this
   is the step the contract cannot do and that a coordinator relies on.
4. Advance both nodes past Alice's commitment deadline. Approve +
   `clientB.commit` Bob's leg on node B. Assert node B lock `Committed`.
5. Advance both nodes into the proposer-claim window. `clientB.claim(secret,
   party=aliceTerms, counterparty=bobTerms)` on node B — Alice claims Bob's
   leg. Assert node B lock `Spent` and Bob's tokens reached Alice's
   recipient.
6. Extract the revealed secret from node B's `Claim` event via the SDK event
   helper; assert it equals the original secret (this is the cross-chain
   mechanism — the taker learns the secret here).
7. Advance both nodes into the taker-claim window.
   `clientA.claim(extractedSecret, party=bobTerms, counterparty=aliceTerms)`
   on node A — Bob claims Alice's leg. Assert node A lock `Spent` and Alice's
   ETH reached Bob's recipient.
8. Assert both legs are `Spent` and final balances/ownership are correct on
   both chains.

## Cross-cutting requirements

- Use bigint for all amounts/timestamps; checksummed addresses for any
  recipient compared against decoded event data.
- The smoke runner must NOT depend on vitest; it is a plain script with
  assertions (throw on mismatch). A minimal local `assert(cond, message)` is
  fine, or import node:assert.
- Time control: use the same Anvil `evm_setNextBlockTimestamp` + mine
  approach the integration suite uses, applied to EACH node independently in
  the cross-chain part (advance both before each cross-chain phase).
- Keep total runtime modest — this is a smoke test; one swap per flow, no
  fuzzing, no exhaustive negative matrix (the two negative assertions named
  above are the only failures it deliberately triggers, and both are
  pure/preflight, not on-chain).
- Output: one line per step (`[A] step 4 ok: proposer committed, lock Free,
  status awaiting-taker-window`), a final `SMOKE PASSED`/`SMOKE FAILED`, and
  a correct exit code. The exit code is what CI keys on.

## Documentation

Add a short "Smoke test" subsection to `sdk/README.md`: what `bun run smoke`
does (one same-chain + one cross-chain swap end-to-end through the workflow
layer, fail-fast), when to run it (fast pre-push / CI gate before the full
integration + cross-chain suites), and that it starts/stops its own Anvils
and needs Foundry installed.
