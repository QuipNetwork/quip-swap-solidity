# Fix — Remove the commit-time QuipWallet preflight; rely on the contract revert

Remove the SDK's pre-submission `vaultIdOf` check in `commit` and instead let
the contract's `onlyQuipWallet` modifier reject non-wallet senders, catching
and surfacing the resulting `CallerNotQuipWallet` revert as a clean,
branchable `NOT_QUIP_WALLET` error. The Solidity contracts in `src/` are the
source of truth and MUST NOT be modified. Conventions as elsewhere:
`QuipSwapError` with codes from the `QuipSwapErrorCode` union, full TSDoc,
bigint everywhere, no new unsafe casts.

After the change: run `bun run check` and `bun run test:integration` from
`sdk/` and do not report complete unless they passed.

## Rationale (why this is safe)

The contract gate is unconditional: `commit` carries `onlyQuipWallet`, which
reverts `CallerNotQuipWallet` when `QUIP_FACTORY.vaultIdOf(msg.sender) ==
bytes32(0)`. Removing the SDK preflight changes nothing about what can
succeed on-chain — a non-wallet commit still fails. The only effect is WHERE
the failure surfaces: at gas estimation (decoded from the revert) instead of
in a pre-submission read. We preserve error quality by mapping the decoded
contract error name to a dedicated SDK code, and we keep the `isQuipWallet`
read available so dapps can still check eligibility proactively.

Known tradeoff (document inline, do not try to solve): the clean
`NOT_QUIP_WALLET` mapping depends on the RPC returning revert data on the
failed `estimateContractGas`. Against a provider that strips revert data the
failure degrades to `GAS_ESTIMATION_FAILED` with no contract name — the
exact reliability gap the removed preflight did not have. This is an accepted
consequence of the removal.

## Changes

### 1. `sdk/src/client.ts` — remove the preflight block in `commit`

Delete step 4 entirely — the `if (!(await isQuipWallet(sender))) { throw ... NOT_QUIP_WALLET ... }`
block (including the `// 4. QuipWallet gate ...` and
`// probably will be removed later ...` comments). Renumber the remaining
commit step comments (the chain-id check becomes the last of the pure
preflights before the window check; keep numbering contiguous). Do NOT remove
the `isQuipWallet` function itself, nor its use anywhere else — only the
inline commit preflight call is removed.

Add a short comment where the block was, e.g.:

```ts
// NOTE: the QuipWallet gate is enforced by the contract's onlyQuipWallet
// modifier, not preflighted here. A non-wallet sender reverts
// CallerNotQuipWallet during gas estimation, surfaced as NOT_QUIP_WALLET by
// wrapContractError. Dapps can check eligibility up front via
// client.isQuipWallet(account). Caveat: the NOT_QUIP_WALLET mapping needs
// the RPC to return revert data; a provider that strips it yields
// GAS_ESTIMATION_FAILED instead.
```

Also update the `commit` TSDoc: remove preflight step 4 ("the sender passes
the QuipWallet gate") from the numbered list and renumber; in `@throws`,
keep `NOT_QUIP_WALLET` (it now arrives via the revert mapping, not the
preflight) and ensure `CONTRACT_REVERT` and `GAS_ESTIMATION_FAILED` are
present.

### 2. `sdk/src/errors.ts` — map the contract error name to NOT_QUIP_WALLET

`NOT_QUIP_WALLET` already exists in the `QuipSwapErrorCode` union — keep it.
In `wrapContractError`, after the contract error name is extracted, map the
specific name to the dedicated code so consumers branch on `err.code`
uniformly instead of on the string field:

```ts
// known contract errors that have a dedicated, branchable SDK code
const CONTRACT_ERROR_CODE: Partial<Record<string, QuipSwapErrorCode>> = {
  CallerNotQuipWallet: 'NOT_QUIP_WALLET',
}

export function wrapContractError(error: unknown, context: string): QuipSwapError {
  const contractErrorName = extractContractErrorName(error)
  const mapped = contractErrorName !== undefined ? CONTRACT_ERROR_CODE[contractErrorName] : undefined
  const suffix = contractErrorName !== undefined ? ` (contract error: ${contractErrorName})` : ''
  return new QuipSwapError({
    code: mapped ?? 'CONTRACT_REVERT',
    message: `${context} reverted${suffix}`,
    ...(contractErrorName !== undefined ? {contractErrorName} : {}),
    cause: error,
  })
}
```

Keep `contractErrorName` populated in BOTH cases (mapped and unmapped) so the
specific name is always available. Document the map with a comment that it is
the single place contract errors get promoted to dedicated codes, and that
others intentionally remain `CONTRACT_REVERT` + `contractErrorName`.

(If a `details` passthrough on `wrapContractError` is added by another fix,
keep it; this change is compatible.)

### 3. Tests

**Mocked-client (`sdk/test/mocked-client/`):**
- A mocked `estimateContractGas` that rejects with a viem
  `ContractFunctionRevertedError` whose `data.errorName` is
  `'CallerNotQuipWallet'` makes `commit` reject with a `QuipSwapError` whose
  `code === 'NOT_QUIP_WALLET'` AND `contractErrorName === 'CallerNotQuipWallet'`.
- `commit` NO LONGER calls `vaultIdOf` as a preflight: assert the mocked
  factory read for `vaultIdOf` is not invoked during a `commit` that
  proceeds to estimation (the only `vaultIdOf` call in the suite now comes
  from an explicit `isQuipWallet` test, not from `commit`).
- A revert whose `errorName` is some OTHER contract error (e.g.
  `TermsMismatch`) still maps to `CONTRACT_REVERT` with that
  `contractErrorName` — proving the map is specific, not catch-all.
- A `unit` test for `wrapContractError` directly: `CallerNotQuipWallet` →
  `NOT_QUIP_WALLET`; unknown name → `CONTRACT_REVERT`; no revert data →
  `CONTRACT_REVERT` with `contractErrorName` undefined.

**Integration (`sdk/test/integration/omnibus.test.ts`), under the
QuipWallet-gating describe block — this is the "actually get and catch the
error" proof against a real chain:**
- Deploy as usual, but do NOT register the committing account with
  `QuipFactoryMock.registerWallet` (or call `unregisterWallet` first). Build
  a fully valid commit (correct terms, window, value) so nothing else can
  fail, then `await expect(client.commit(...))` rejects with a
  `QuipSwapError` whose `code === 'NOT_QUIP_WALLET'` and
  `contractErrorName === 'CallerNotQuipWallet'`. This proves the contract
  actually throws `CallerNotQuipWallet` and the SDK catches+maps it through
  the live `estimateContractGas` path on Anvil (which returns revert data).
- Sanity counterpart: after `registerWallet`, the same commit SUCCEEDS —
  proving the gate, not some unrelated failure, was the cause.
- `client.isQuipWallet(account)` returns `false` for the unregistered
  account and `true` after registration (the proactive read still works).
- Keep any existing claim/reclaim-from-unregistered-account tests: those are
  permissionless and must still succeed regardless of registration.

Remove or update any existing test that asserted a PRE-submission
`NOT_QUIP_WALLET` (i.e. that `commit` threw before estimation / without an
RPC revert) — that behavior is intentionally gone; the error now comes from
the estimation path.

### 4. Docs

If `sdk/README.md` or the spec markdown states that the SDK preflights the
QuipWallet gate before submission, update it: the gate is contract-enforced
and surfaced as `NOT_QUIP_WALLET` via the revert; dapps may call
`isQuipWallet` for proactive UX. Note the RPC-revert-data caveat in one line.
