# Fix — Remove the commit-time QuipWallet preflight (no SDK-side wallet coupling)

Remove the SDK's pre-submission `vaultIdOf` check in `commit`. Let the
contract reject non-wallet senders and let the resulting revert surface
through the EXISTING generic decode path — `CONTRACT_REVERT` with
`contractErrorName` populated — adding NO wallet-specific code, mapping, or
type to the SDK. The Solidity contracts in `src/` are the source of truth and
MUST NOT be modified. Conventions as elsewhere: `QuipSwapError` with codes
from the `QuipSwapErrorCode` union, full TSDoc, bigint everywhere, no new
unsafe casts.

After the change: run `bun run check` and `bun run test:integration` from
`sdk/` and do not report complete unless they passed.

## Rationale (why no mapping, why now)

The contract currently gates `commit` with `onlyQuipWallet`
(`QUIP_FACTORY.vaultIdOf(msg.sender) == 0 → revert CallerNotQuipWallet`).
**This gate is planned for removal — the protocol is moving wallet-agnostic.**
Therefore the SDK must NOT encode the QuipWallet concept as a first-class
error code or a name→code mapping: anything wallet-specific becomes dead
weight (and misleading dead weight) the moment the modifier is dropped.

The right posture is: the SDK does not preflight the gate and does not name
it. While the modifier exists, a non-wallet commit reverts at gas estimation
and is surfaced by the EXISTING `wrapContractError` as a generic
`CONTRACT_REVERT` whose `contractErrorName` is `'CallerNotQuipWallet'` — so
the reason is still fully visible for debugging today. When the modifier is
removed later, that revert simply stops happening; the SDK needs ZERO changes
because nothing references it.

Accepted tradeoffs (document inline, do not solve):
- The failure now surfaces at estimation, not before — one estimation
  round-trip is spent, and the clean `contractErrorName` depends on the RPC
  returning revert data (a stripping provider yields `GAS_ESTIMATION_FAILED`
  with no name). Acceptable: this is transitional behavior for a gate that is
  going away.

## Changes

### 1. `sdk/src/client.ts` — remove the preflight block in `commit`

Delete step 4 entirely — the
`if (!(await isQuipWallet(sender))) { throw ... 'NOT_QUIP_WALLET' ... }`
block, including its `// 4. QuipWallet gate ...` and
`// probably will be removed later ...` comments. Renumber the remaining
commit step comments to stay contiguous. Replace the deleted block with a
brief note:

```ts
// The contract currently gates commit with onlyQuipWallet, but that gate is
// being removed (protocol going wallet-agnostic), so the SDK does NOT
// preflight or name it. While it exists, a non-wallet sender reverts
// CallerNotQuipWallet at estimation, surfaced generically as CONTRACT_REVERT
// (contractErrorName: 'CallerNotQuipWallet'). No SDK change is needed when
// the modifier is later dropped.
```

Update the `commit` TSDoc: remove preflight step 4 ("the sender passes the
QuipWallet gate") from the numbered list and renumber. In `@throws`, REMOVE
`NOT_QUIP_WALLET` and ensure `CONTRACT_REVERT` and `GAS_ESTIMATION_FAILED`
are listed (the gate failure now arrives via those).

### 2. `sdk/src/client.ts` — decide on `isQuipWallet`

`isQuipWallet` is no longer called by `commit`. Keep the method, but
re-document it as an OPTIONAL, TRANSITIONAL convenience that reflects the
current contract gate and may be removed when the gate is:

```
/**
 * Convenience read of QUIP_FACTORY.vaultIdOf(account) != 0, reflecting the
 * contract's CURRENT onlyQuipWallet gate on commit. TRANSITIONAL: the gate
 * is being removed as the protocol moves wallet-agnostic; do not build
 * durable logic on this method. Not used internally by commit.
 */
```

Do not remove `getQuipFactory` or the `quipFactoryAbi` constant (still used
by `isQuipWallet` and harmless to keep).

### 3. `sdk/src/errors.ts` — remove the `NOT_QUIP_WALLET` code

Remove `'NOT_QUIP_WALLET'` from the `QuipSwapErrorCode` union, since nothing
produces it anymore and it names a concept the SDK is intentionally not
coupling to. Do NOT add any name→code mapping to `wrapContractError`; leave
that function exactly as it is (generic `CONTRACT_REVERT` + `contractErrorName`).
After removal, run the typechecker and fix any now-dangling references (there
should be only the deleted commit block and any test that asserted the code).

### 4. Tests

**Mocked-client (`sdk/test/mocked-client/`):**
- `commit` NO LONGER calls `vaultIdOf` as a preflight: assert the mocked
  factory `vaultIdOf` read is not invoked during a `commit` that proceeds to
  estimation.
- A mocked `estimateContractGas` that rejects with a viem
  `ContractFunctionRevertedError` whose `data.errorName` is
  `'CallerNotQuipWallet'` makes `commit` reject with a `QuipSwapError` whose
  `code === 'CONTRACT_REVERT'` and `contractErrorName === 'CallerNotQuipWallet'`
  (proving the reason is still visible without a dedicated code).

**Integration (`sdk/test/integration/omnibus.test.ts`), QuipWallet-gating
describe block — the live proof:**
- Without registering the committing account
  (`QuipFactoryMock.registerWallet`), build a fully valid commit (correct
  terms, window, value so nothing else can fail) and assert
  `client.commit(...)` rejects with a `QuipSwapError` whose
  `code === 'CONTRACT_REVERT'` and
  `contractErrorName === 'CallerNotQuipWallet'`. This shows the contract
  throws the gate error and the SDK surfaces it generically through the live
  estimation path on Anvil.
- Sanity counterpart: after `registerWallet`, the same commit SUCCEEDS.
- Keep claim/reclaim-from-unregistered-account tests (permissionless; still
  succeed).
- Remove/replace any existing test asserting a pre-submission
  `NOT_QUIP_WALLET` code — that behavior and that code are gone.

### 4. Tests

The specific edits below are derived from the CURRENT test files — apply
exactly these, do not invent additional cases.

#### 4a. `sdk/test/mocked-client/client.test.ts` — five precise edits

1. **DELETE the preflight-rejection test.** In `describe('commit
   orchestration')`, remove the whole `it('rejects a non-QuipWallet sender
   BEFORE submission', ...)` test (the one that sets
   `vaultId: '0x00..00'` and asserts code `'NOT_QUIP_WALLET'` and that
   `estimate:commit` is absent). That behavior is gone — `commit` no longer
   preflights the gate, so a zero vaultId would now proceed to estimation
   and (in this mock, which returns a gas estimate) SUCCEED. Do not convert
   it to expect success; just delete it (the gate's real behavior is proven
   in the integration suite, 4b).

2. **REPLACE the ordering assertion.** In `it('reads commitmentFee,
   vaultIdOf, and lock state BEFORE estimating ...')`, remove the
   `expect(seq.indexOf('read:vaultIdOf')).toBeLessThan(...)` line and drop
   `vaultIdOf` from the test name/description. `commit` must no longer read
   `vaultIdOf` at all, so keep only the `commitmentFee` and `lockState`
   ordering assertions. Rename to e.g. `'reads commitmentFee and lock state
   BEFORE estimating, and estimates BEFORE writing'`.

3. **ADD a negative assertion** to the same ordering test (or a small new
   `it`): assert `commit` NEVER reads `vaultIdOf` —
   `expect(mocks.log.sequence).not.toContain('read:vaultIdOf')`. This pins
   the removal so a future re-introduction is caught.

4. **ADD a revert-path test** in `describe('gas estimation and balance
   preflight')`, mirroring the existing `InvalidLockState` decode test:
   construct a `ContractFunctionRevertedError` via `encodeErrorResult({abi:
   omnibusAbi, errorName: 'CallerNotQuipWallet'})`, set it as
   `estimateError` on a fresh-lock commit setup
   (`setup({lockState: LockState.Unused, estimateError: revert})`), call
   `commit`, and assert the rejection has `code === 'CONTRACT_REVERT'` and
   `contractErrorName === 'CallerNotQuipWallet'`. This proves the gate
   error is still fully visible WITHOUT a dedicated code. (Confirm
   `CallerNotQuipWallet` is in `omnibusAbi`; it is, via `IOmnibus`.)

5. **KEEP unchanged** the `describe('reads')` block's two `isQuipWallet`
   tests — the method survives as a transitional convenience and these
   still pass. (They are the ONLY remaining `vaultIdOf` reads in the suite,
   which is what makes assertion #3 meaningful.)

#### 4b. `sdk/test/integration/omnibus.test.ts` — the live proof

In the QuipWallet-gating describe block:
- Without registering the committing account
  (`QuipFactoryMock.registerWallet`), build a fully valid commit (correct
  terms, window, exact value, fresh lock so nothing else can fail) and
  assert `client.commit(...)` rejects with a `QuipSwapError` whose
  `code === 'CONTRACT_REVERT'` and
  `contractErrorName === 'CallerNotQuipWallet'`. This proves the contract
  throws the gate error and the SDK surfaces it generically through the
  live `estimateContractGas` path on Anvil (which returns revert data).
- If an existing test here asserted a pre-submission `NOT_QUIP_WALLET`
  code, convert it to the above (`CONTRACT_REVERT` + `contractErrorName`).
- Sanity counterpart: after `registerWallet`, the same commit SUCCEEDS
  (proves the gate, not an unrelated failure, was the cause).
- KEEP claim/reclaim-from-unregistered-account tests (permissionless;
  still succeed regardless of registration).

#### 4c. `sdk/src/errors.ts` consumers

After removing `'NOT_QUIP_WALLET'` from the union (change 3), the
typechecker will flag any remaining reference. The only expected ones are
the deleted mocked test (4a.1) and possibly a `@throws` tag in the `commit`
TSDoc (change 1). Grep the whole `sdk/` tree for `NOT_QUIP_WALLET` and
confirm zero references remain after the edits.

### 5. Docs (`sdk/README.md`) — apply all of the following

The README currently presents the gate as SDK-preflighted and
`NOT_QUIP_WALLET` as a real code. Correct every such spot AND add a short
subsection explaining the transitional stance.

**5a. Rewrite the "The QuipWallet gate on commit" section.** Replace its
bullet list so it no longer claims a preflight or a dedicated code. New
content must convey:
- The gate is enforced by the contract's `onlyQuipWallet` modifier (keep
  the solidity snippet).
- It is **transitional** — the protocol is moving wallet-agnostic and the
  modifier is planned for removal; the SDK deliberately does NOT preflight
  or name it, so no SDK change is needed when it is dropped.
- While the gate exists, a non-wallet `commit` reverts at gas estimation
  and surfaces as `CONTRACT_REVERT` with
  `contractErrorName === 'CallerNotQuipWallet'` (not a dedicated code).
- Caveat: the clean `contractErrorName` depends on the RPC returning revert
  data; a provider that strips it yields `GAS_ESTIMATION_FAILED` instead.
- `client.isQuipWallet(account)` remains as an OPTIONAL, transitional
  proactive check (reads `vaultIdOf` on `QUIP_FACTORY`); it is no longer run
  automatically before `commit`. Do not build durable logic on it.
- Keep the existing true facts: the committer is the QuipWallet CONTRACT
  address (never the owner EOA); `claim`/`reclaim` are ungated;
  `QuipFactoryMock.registerWallet` is a test convenience.

**5b. Fix the write-flow pipeline list ("Write flow: gas estimation ...").**
In step 1 ("Protocol preflights"), remove "the QuipWallet gate (commit)"
from the enumerated preflights — it is no longer a preflight. Leave the
lock-state/window/chain-id items intact.

**5c. Fix the "Error handling" example and prose.** In the `catch` example,
change the illustrative `err.code` union comment so it no longer lists
`'NOT_QUIP_WALLET'` (use e.g. `'WINDOW_VIOLATED' | 'INVALID_LOCK_STATE' |
'CONTRACT_REVERT'`). Keep `CallerNotQuipWallet` in the `err.contractErrorName`
example list (it is still a decodable contract error name) and in the
`IOmnibus` decoded-errors paragraph — those describe contract errors, which
are unchanged. The point to land: the gate failure is fully visible via
`contractErrorName`, just not via a dedicated `code`.

**5d. Add a new subsection titled "Catching contract reverts"** immediately
after the "Error handling" section. It should explain, with a short code
example, that any contract revert reaching the SDK is decoded: the SDK
surfaces it as a `QuipSwapError` with `code: 'CONTRACT_REVERT'`,
`contractErrorName` set to the Solidity error name (when the RPC returns
revert data), and `cause` preserving the original viem error — no
per-error SDK code is required to see what failed. Use a durable example
that will outlive the gate, e.g. committing with an incorrect `msg.value`
surfacing `contractErrorName: 'IncorrectNativeAmountReceived'`, and mention
the `CallerNotQuipWallet` gate as the current transitional case. State the
RPC-revert-data caveat once. This subsection is the user-facing companion
to the integration test in 4b/the durable revert test.

**5e. Spec markdown.** If the prompt/spec markdown at the repository root
states the SDK preflights or names the QuipWallet gate, update it to match
5a so a future agent session does not re-introduce the preflight.

After the doc edits, grep `sdk/README.md` for `NOT_QUIP_WALLET` and confirm
zero occurrences remain.
