# SDK Changes — Round 1

Implementation record for [`sdk_fixes_round1.md`](sdk_fixes_round1.md). All four
fixes are implemented; no production Solidity in `src/` was touched.

Verification (all executed, all passing):

| Command (from `sdk/`)    | Result                                                  |
| ------------------------ | ------------------------------------------------------- |
| `bun run check`          | typecheck clean, 138 unit + mocked tests, build succeeds |
| `bun run test:integration` | 43 tests (34 integration + 9 differential)             |
| `bun run test:cross-chain` | 5 tests                                                 |

---

## Fix 1 — Lock-state preflight for claim, reclaim, and commit

**Problem recap:** `posted` and `termsHash` are never cleared when a lock is
spent, so the old `termsHash`+`posted`-only preflight let claims on Spent
locks, reclaims on Spent/Unused locks, and duplicate same-side commits sail
through to simulation and die as generic `CONTRACT_REVERT`s.

### `sdk/src/errors.ts`

- Added two codes to the `QuipSwapErrorCode` union (documented in the
  existing grouped-comment style):
  - `INVALID_LOCK_STATE` — preflight equivalent of the contract's
    `InvalidLockState` / `InvalidLockAdvancement`.
  - `TERMS_ALREADY_POSTED` — preflight equivalent of `TermsAlreadyPosted`.

### `sdk/src/client.ts`

- Replaced the old `verifyPostedState` helper with:
  - `readLockBatch(lock, postedDigest)` — ONE `Promise.all` over
    `lockState`, `termsHash`, and `posted` (the `lockState` read joins the
    existing parallel batch; no added sequential latency).
  - `verifyClaimState` — requires `lockState === Committed`; otherwise
    throws `INVALID_LOCK_STATE` with `details: {lock, lockState, required:
    'Committed'}` and a per-state cause in the message (Unused → "nothing
    has been committed under this lock on this chain"; Free → "the
    counterparty has not committed yet"; Spent → "already claimed or
    reclaimed"). Then checks `termsHash` and counterparty `posted` as
    before (`TERMS_NOT_ON_CHAIN`).
  - `verifyReclaimState` — requires `Free` or `Committed` (mirroring
    `_advanceLockTo`'s Free→Spent / Committed→Spent), with the actual state
    in details; then `termsHash` + party-side `posted`.
  - `verifyCommitState` — NEW commit-side preflight: `Spent`/`Committed`
    → `INVALID_LOCK_STATE` (no commit can advance from those states);
    `Free` → requires `termsHash(lock)` to equal
    `digestTermsCanonically(party, counterparty)` (`TERMS_NOT_ON_CHAIN` on
    mismatch) and `posted(lock, digestTerms(party))` to be `false`
    (`TERMS_ALREADY_POSTED` otherwise — the second same-chain commit must
    post the OTHER side); `Unused` → no extra requirement. All three reads
    go out in the same parallel batch regardless of state.
- `CommitArgs` gained `verifyOnChainState?: boolean` (default `true`),
  symmetric with `ClaimArgs`/`ReclaimArgs`. The flag's meaning is unchanged
  ("extra on-chain reads before submission"); with it off, behavior falls
  through to the gas-estimation revert check, which still catches
  everything as a decoded `CONTRACT_REVERT`.
- TSDoc updated on `commit`/`claim`/`reclaim` (preflight step lists,
  `@throws` lists) and on all three args interfaces.

### Tests

- Mocked (`sdk/test/mocked-client/client.test.ts`): per-state
  `INVALID_LOCK_STATE` for claim (Unused/Free/Spent, message + details
  asserted); reclaim accepts Free/Committed and rejects Unused/Spent;
  commit rejects Spent/Committed, rejects Free+already-posted with
  `TERMS_ALREADY_POSTED`, rejects Free+termsHash-mismatch with
  `TERMS_NOT_ON_CHAIN`, accepts Free+matching+un-posted; every rejection
  proven to occur BEFORE `estimateContractGas`; `verifyOnChainState: false`
  proven to skip the `lockState` read and fall through to estimation.
- Integration (`sdk/test/integration/omnibus.test.ts`, real Anvil):
  - claim on a Spent lock → `INVALID_LOCK_STATE` preflight (not
    `CONTRACT_REVERT`); same call with `verifyOnChainState: false` →
    `CONTRACT_REVERT` with decoded `InvalidLockState` via the estimation
    path.
  - claim on a Free (half-committed) lock → `INVALID_LOCK_STATE` with the
    "counterparty has not committed" cause; raw contract call agrees.
  - reclaim on an Unused lock → `INVALID_LOCK_STATE`; with the flag off →
    decoded `TermsMismatch` (the contract hits its termsHash check first
    for unused locks).
  - duplicate same-side commit → `TERMS_ALREADY_POSTED` preflight; with the
    flag off → decoded `TermsAlreadyPosted`; raw call agrees.
  - second commit with mismatched counterparty terms → `TERMS_NOT_ON_CHAIN`
    preflight; with the flag off → decoded `TermsMismatch`; raw call agrees.

## Fix 2 — Explicitly SKIPPED: party-side `posted` check in same-chain claim

No party-side `posted(lock, digestTerms(party))` read was added to the
claim preflight. The rationale is encoded as a comment block on
`verifyClaimState` in `sdk/src/client.ts` so a future contributor doesn't
"complete" the check: the contract's party-side `_enforcePosted` branch is
unreachable cross-chain (it runs only when `party.chainId ==
block.chainid`), and for same-chain swaps `Committed` is provably reachable
only with both sides posted — so with the `Committed` preflight in place
the read has zero information content. The comment also records why the
counterparty-side `posted` read is KEPT despite being equally implied: it
costs no latency inside the `Promise.all` and localizes which value
disagrees under an RPC race.

## Fix 3 — Docstring correction: `proposer-commit-expired`

`sdk/src/workflows/sameChain.ts`: the `'proposer-commit-expired'` variant's
docstring no longer claims "the swap is dead". It now states precisely
that the swap can no longer COMPLETE, but the contract will still accept a
(pointless, self-harming) taker-first commit in
`[proposer.commitmentDeadline, taker.commitmentDeadline)` — `Omnibus.commit`
checks only the window, not that the proposer actually committed — which
moves the lock Unused→Free and strands the taker's assets until
`taker.reclaimRelease`. Consumers must treat the status as terminal and not
commit into it. Status name unchanged; no logic changes.

## Fix 4 — Gas estimation with a safety multiplier (replaces simulateContract)

### New module `sdk/src/gas.ts`

- Constants: `DEFAULT_GAS_MULTIPLIER = 1.2`, `MIN_GAS_MULTIPLIER = 1.0`,
  `MAX_GAS_MULTIPLIER = 2.0`.
- `TxOptions` interface (all fields optional): `gas` (verbatim limit —
  skips estimation AND the multiplier), `gasMultiplier` (default 1.2,
  clamped to [1.0, 2.0], non-finite → 1.0), `maxFeePerGas` /
  `maxPriorityFeePerGas` (EIP-1559, exclusive with `gasPrice`), `gasPrice`
  (legacy), `nonce` (pin; default viem fetches), `skipPreflightChecks`
  (skips the BALANCE preflight ONLY — protocol preflights always run).
- `resolveGasMultiplier(opts)` and `applyGasMultiplier(estimate, opts)`
  exported separately. Multiplier math is bigint-safe and deterministic —
  rounded to exactly 3 decimals by integer scaling
  (`(estimate * BigInt(Math.round(m * 1000))) / 1000n`); a bigint is never
  multiplied by a float.
- `buildFeeOverrides(opts)` returns ONLY the explicitly-set fee fields, so
  viem's automatic fee pricing keeps working for everything unset (no
  `undefined` passthrough).
- `prepareTx({publicClient, contractParams, totalValue, opts})` →
  `{gas, fees, nonce?}`, staged:
  1. **Gas estimation** — `opts.gas` used verbatim when set; otherwise
     `publicClient.estimateContractGas(contractParams)`. Contract reverts
     surface here wrapped by `wrapContractError` (decoded name + original
     cause preserved) — this REPLACES `simulateContract` as the
     pre-submission revert check. Non-revert failures throw
     `GAS_ESTIMATION_FAILED` with the original error as `cause`.
  2. **Multiplier** — applied to the estimate (skipped with explicit gas).
  3. **Balance preflight** (unless `skipPreflightChecks`) — runs AFTER
     estimation; requires `totalValue + gas * feePerGas` using the buffered
     gas and the caller's `maxFeePerGas`/`gasPrice` if set, else
     `publicClient.estimateFeesPerGas()`, else (no fee data) `totalValue`
     alone. Throws `BALANCE_TOO_LOW` with `{required, balance}` in details.

### `sdk/src/errors.ts`

- Added `GAS_ESTIMATION_FAILED` and `BALANCE_TOO_LOW` to the
  `QuipSwapErrorCode` union.

### `sdk/src/client.ts`

- Every write (`commit`, `claim`, `reclaim`, and all four `admin.*`
  methods) now runs: pure protocol preflights FIRST (structural, pairing,
  window, chain-id, quip-wallet for commit, Fix 1's lock-state checks) →
  `prepareTx` → `writeContract` with the prepared `gas`/`fees`/`nonce`
  spread in. The `simulateContract` step is removed from every write
  (a shared `submitWrite` helper implements the pipeline).
- Public write signatures gained an optional final `opts?: TxOptions`:
  `commit(args, opts?)`, `claim(args, opts?)`, `reclaim(args, opts?)`,
  `admin.setCommitmentFee(newFee, opts?)`, `admin.withdrawFees(to, opts?)`,
  `admin.transferOwnership(newOwner, opts?)`, `admin.acceptOwnership(opts?)`.
- Docstrings document the buffer rationale: unused gas is refunded, so the
  1.2x buffer costs nothing at execution; it prevents out-of-gas failures
  from state drift between estimation and inclusion — which matters in this
  protocol because writes happen inside closing time windows and an OOG'd
  claim near a window boundary may be unrecoverable.
- For commit, `totalValue` passed to the balance preflight is exactly
  `totalNative(party) + commitmentFee` (the value the client already
  computes); `0n` for claim/reclaim/admin.
- Note: `submitApproval` in `sdk/src/approvals.ts` still uses
  `simulateContract` — the fix scopes the replacement to the client's write
  methods, and the spec markdown's "use simulation for approval
  transactions" guidance still stands.

### `sdk/src/index.ts`

- Exports the new gas surface: the three multiplier constants,
  `resolveGasMultiplier`, `applyGasMultiplier`, `buildFeeOverrides`,
  `prepareTx`, and the `TxOptions` / `FeeOverrides` / `PrepareTxArgs` /
  `PrepareTxContractParams` / `PreparedTx` types.

### Tests

- Unit (`sdk/test/unit/gas.test.ts`, new — 11 tests): default 1.2
  (`100_000n → 120_000n`); clamping (`0.5 → 1.0`, `5 → 2.0`,
  `NaN`/`±Infinity → 1.0`); 3-decimal honoring (`1.137` on `1_000_000n →
  1_137_000n`); exact bigint math for large estimates (10^30 and 10^18+1 —
  values floats cannot carry); explicit `opts.gas` bypasses estimation and
  multiplier (proven with a mock that throws if estimation is attempted);
  selective fee forwarding; nonce forwarded only when pinned.
- Mocked (`sdk/test/mocked-client/client.test.ts`, rewritten for the new
  flow — 38 tests): `estimateContractGas` receives the exact contract
  params (function, args, value, account); `writeContract` receives the
  BUFFERED gas (120_000n from a 100_000n estimate); a real
  `ContractFunctionRevertedError` thrown during estimation produces a
  decoded `CONTRACT_REVERT` with `contractErrorName`, while a plain network
  error produces `GAS_ESTIMATION_FAILED` with the cause preserved; a
  zero-balance sender produces `BALANCE_TOO_LOW` before any write;
  `skipPreflightChecks` skips only the balance read and never the protocol
  preflights (window violation still rejects with it set); explicit
  `opts.gas` + fee overrides land verbatim in the write request. All
  former simulate-before-write assertions now assert
  estimate-before-write.
- Integration (real Anvil): every pre-existing commit/claim/reclaim happy
  path now runs end-to-end through the estimate+buffer flow (34 tests
  green); a zero-balance account attempting a permissionless claim is
  rejected `BALANCE_TOO_LOW` before any transaction (lock stays
  `Committed`, then a funded claimer settles it); explicit `TxOptions`
  honored on a real transaction (gas 400_000n verbatim — no multiplier —
  and pinned EIP-1559 fees verified on the mined transaction); revert
  conditions with `verifyOnChainState: false` (double claim, duplicate
  commit, mismatched second commit) surface through the estimation path
  with the correct decoded contract error names.

### Documentation sync

- `sdk/README.md`: the client bullet now says "preflighted writes with
  node-side gas estimation and a safety-buffered gas limit", and a new
  section **"Write flow: gas estimation, safety buffer, and TxOptions"**
  documents the five-stage pipeline, the buffer rationale, the lock-state
  preflight, and a full `TxOptions` example.
- `quip_swap_sdk_claude_code_prompt.md` (root spec): Section 15 rewritten
  from "all writes must use Viem simulation" to the estimate-based flow
  (estimation as the revert check, multiplier semantics, balance preflight,
  `TxOptions`), so future sessions don't "fix" the code back; the commit/
  claim/reclaim step lists, the Section 24 mocked-test expectations, and
  the two "immediately before simulation" phrases were updated to match.
  The claim/reclaim "optionally verify" steps now mention the lock-state
  check from Fix 1.

---

## File-by-file summary

| File | Change |
| --- | --- |
| `sdk/src/errors.ts` | +4 error codes: `INVALID_LOCK_STATE`, `TERMS_ALREADY_POSTED`, `GAS_ESTIMATION_FAILED`, `BALANCE_TOO_LOW` |
| `sdk/src/gas.ts` | NEW — multiplier constants, `TxOptions`, `resolveGasMultiplier`, `applyGasMultiplier`, `buildFeeOverrides`, `prepareTx` |
| `sdk/src/client.ts` | lock-state preflights (`readLockBatch`, `verifyClaimState`, `verifyReclaimState`, `verifyCommitState`), Fix 2 skip-rationale comment, `CommitArgs.verifyOnChainState`, estimate-based `submitWrite` pipeline replacing every `simulateContract`, `opts?: TxOptions` on all 7 write methods, TSDoc updates |
| `sdk/src/workflows/sameChain.ts` | Fix 3 docstring rewrite for `'proposer-commit-expired'` |
| `sdk/src/index.ts` | gas module exports |
| `sdk/test/unit/gas.test.ts` | NEW — 11 multiplier/prepareTx unit tests |
| `sdk/test/mocked-client/client.test.ts` | rewritten mocks (estimateContractGas / getBalance / estimateFeesPerGas / lockState), 17 new tests (21 → 38) |
| `sdk/test/integration/omnibus.test.ts` | lock-state preflight scenarios (preflight + flag-off estimation + raw-contract parity), balance-preflight test, explicit-TxOptions test (31 → 34) |
| `sdk/README.md` | write-flow section + client bullet |
| `quip_swap_sdk_claude_code_prompt.md` | Section 15 / step lists / Section 24 updated to the estimate-based flow |

Test totals after this round: 138 unit+mocked, 43 integration (incl. 9
differential), 5 cross-chain — all passing; `bun run check` (typecheck +
tests + build) passes.
