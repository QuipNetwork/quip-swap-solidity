# Gas Fix — Simplify `prepareTx` (balance check first, drop fee fetching)

Standalone fix for the `sdk/` TypeScript SDK (extracted from Round 2; run it
on its own). The Solidity contracts in `src/` are the source of truth and
MUST NOT be modified. Same conventions as the earlier fix rounds:
`QuipSwapError` with codes from the `QuipSwapErrorCode` union, full TSDoc,
bigint everywhere, no new unsafe casts.

This document is SELF-CONTAINED: the target semantics come from our wallet
SDK (`@quip.network/ethereum-sdk`, `src/v1/gas.ts`), which is NOT in this
repository — do not try to read it; everything needed is reproduced below.
(For humans: it lives at
`/Users/ridham/Documents/quip_network/ethereum-sdk/src/v1/gas.ts`.)

After the fix: run `bun run check` and `bun run test:integration` from
`sdk/` and do not report the task complete unless the commands actually
passed.

---

## Problem

Two issues with one root cause. First: `eth_estimateGas` validates that the
sender's balance covers the transaction `value`, and `prepareTx` currently
runs the balance preflight AFTER estimation — so an underfunded commit
sender fails inside estimation with the node's insufficient-funds error,
surfacing as a misleading `GAS_ESTIMATION_FAILED` while the `BALANCE_TOO_LOW`
error stays unreachable for its most common trigger. Second: the
post-estimation ordering exists only so the check can require
`totalValue + gas * feePerGas`, which drags in `estimateFeesPerGas`, its
try/catch fallback, and a no-fee-data branch — complexity our wallet SDK's
equivalent module deliberately does not have.

## Target semantics (reference implementation)

This is the wallet SDK's proven shape, adapted to THIS codebase's
conventions (`QuipSwapError` codes instead of error subclasses; keep this
SDK's existing names, TSDoc style, and the existing
`isContractRevert`/`wrapContractError` helpers). Everything already
identical in the current `sdk/src/gas.ts` — `TxOptions`, the multiplier
constants, `resolveGasMultiplier`, `applyGasMultiplier`, `buildFeeOverrides`,
`PreparedTx`, the `CONTRACT_REVERT` vs `GAS_ESTIMATION_FAILED` split — stays
as it is. Only the pieces below change.

New exported helper (mirror of the wallet SDK's `preflightBalanceCheck`):

```ts
/**
 * Throws BALANCE_TOO_LOW if the account's balance is below `required`.
 * No-op when `required <= 0n` — value-less calls (claim/reclaim/admin)
 * have no balance preflight; their send-time funds failures are mapped
 * in submitWrite (see client.ts).
 */
export async function preflightBalanceCheck(
  publicClient: PublicClient,
  account: Address,
  required: bigint,
): Promise<void> {
  if (required <= 0n) return
  const balance = await publicClient.getBalance({address: account})
  if (balance < required) {
    throw new QuipSwapError({
      code: 'BALANCE_TOO_LOW',
      message: `Sender ${account} holds ${balance} wei but the call requires ${required} wei of value`,
      details: {required, balance},
    })
  }
}
```

New `prepareTx` stage order (replaces the current body; signature, params
interfaces, and return shape are unchanged):

```ts
export async function prepareTx(args: PrepareTxArgs): Promise<PreparedTx> {
  const {publicClient, contractParams, totalValue, opts = {}} = args

  // Stage 1: balance — BEFORE estimation, bare totalValue only. This is
  // the one stage skipPreflightChecks disables. Running it first fixes a
  // masking bug by construction: any sender reaching estimation already
  // covers the value, and viem attaches no gas price to eth_estimateGas,
  // so the node cannot fail estimation on funds — insufficient funds can
  // no longer masquerade as GAS_ESTIMATION_FAILED.
  if (opts.skipPreflightChecks !== true) {
    await preflightBalanceCheck(publicClient, contractParams.account, totalValue)
  }

  // Stage 2: gas — explicit opts.gas is used verbatim (no estimation, no
  // multiplier); otherwise estimate (contract reverts surface here,
  // decoded — this is the pre-submission revert check) and buffer.
  let gas: bigint
  if (opts.gas !== undefined) {
    gas = opts.gas
  } else {
    let estimate: bigint
    try {
      estimate = await publicClient.estimateContractGas(/* unchanged */)
    } catch (error) {
      if (isContractRevert(error)) {
        throw wrapContractError(error, `Estimating gas for ${contractParams.functionName}`)
      }
      throw new QuipSwapError({code: 'GAS_ESTIMATION_FAILED', /* unchanged */ cause: error})
    }
    gas = applyGasMultiplier(estimate, opts)
  }

  return {gas, fees: buildFeeOverrides(opts), ...(opts.nonce !== undefined ? {nonce: opts.nonce} : {})}
}
```

## Changes

1. Reorder `prepareTx` (`sdk/src/gas.ts`) to the reference shape above:
   balance preflight FIRST (stage 1), bare `totalValue` only, no-op when
   `totalValue <= 0n`, the one stage `skipPreflightChecks` disables.
   Extract it as the exported `preflightBalanceCheck(publicClient, account,
   required)` shown above.
2. DELETE the post-estimation balance block entirely: the
   `estimateFeesPerGas` call, its fallback chain, and the
   `totalValue + gas * feePerGas` math. The worst-case-fee balance check is
   intentionally dropped (gas funding is the wallet app's concern in the
   WalletConnect flow, and send-time failures are handled in item 4). Do
   not re-add it.
3. Carry the stage-1 comment block from the reference into the `prepareTx`
   docstring (the masking-bug-fixed-by-construction explanation).
4. Error-quality keeper for value-less calls (claim/reclaim/admin, which
   now have NO balance preflight): in `submitWrite`'s catch in
   `sdk/src/client.ts`, before falling through to `wrapContractError`,
   walk the viem error chain for `InsufficientFundsError`:

   ```ts
   import {BaseError, InsufficientFundsError} from 'viem'

   if (error instanceof BaseError && error.walk(e => e instanceof InsufficientFundsError) !== null) {
     throw new QuipSwapError({
       code: 'BALANCE_TOO_LOW',
       message: `Sender cannot cover gas for ${params.functionName}; fund the account and retry`,
       cause: error,
     })
   }
   ```

   — a gas-unfunded relayer's send-time failure must not be mislabeled
   `CONTRACT_REVERT`.
5. Update the `TxOptions.skipPreflightChecks` TSDoc (it now skips the
   stage-1 value check) and the README write-flow section to the new
   order: balance → estimate (revert check) → multiplier.
6. Tests:
   - mocked: an underfunded-for-value sender produces `BALANCE_TOO_LOW`
     and `estimateContractGas` is NEVER called (assert the mock saw no
     estimation); a send-time `InsufficientFundsError` from `writeContract`
     surfaces as `BALANCE_TOO_LOW`, not `CONTRACT_REVERT`; a plain network
     failure during estimation still produces `GAS_ESTIMATION_FAILED`; a
     contract revert during estimation still produces `CONTRACT_REVERT`
     with `contractErrorName`.
   - integration: an underfunded commit sender gets `BALANCE_TOO_LOW`
     before any transaction exists; REMOVE the covers-value-but-not-gas
     scenario if one exists (no longer preflighted by design).
   - keep all multiplier/clamp/fee-override unit tests unchanged.
