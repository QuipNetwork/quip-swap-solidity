/**
 * Receipt helpers.
 *
 * A returned transaction hash is NOT confirmation: the transaction may
 * still be pending, may revert, or may be dropped/replaced. These helpers
 * wait for a receipt, check `status`, and decode the relevant Omnibus
 * events into typed results.
 *
 * Submission ({@link OmnibusClient.commit} et al.) and receipt waiting are
 * deliberately separate so the application chooses its own confirmation
 * count, timeout, retry, and finality policy per call.
 */
import type {Hash, PublicClient, TransactionReceipt} from 'viem'
import {QuipSwapError, wrapContractError} from './errors.js'
import {decodeClaimEvents, decodeCommitmentEvents, decodeReclaimedEvents} from './events.js'
import type {ClaimEvent, CommitmentEvent, ReclaimedEvent} from './events.js'

/** Options forwarded to `publicClient.waitForTransactionReceipt`. */
export interface WaitOptions {
  /** Number of confirmations to wait for (default: the client's default, 1). */
  readonly confirmations?: number
  /** Milliseconds to wait before giving up. */
  readonly timeout?: number
}

/** A successful, decoded Omnibus transaction result. */
export interface OmnibusReceipt {
  /** The transaction hash that was waited on. */
  readonly transactionHash: Hash
  /** The full Viem receipt (status is guaranteed `'success'`). */
  readonly receipt: TransactionReceipt
  /** Decoded `Commitment` events emitted by the transaction (0 or 1). */
  readonly commitments: readonly CommitmentEvent[]
  /** Decoded `Claim` events emitted by the transaction (0 or 1). */
  readonly claims: readonly ClaimEvent[]
  /** Decoded `Reclaimed` events (0, 1, or 2 — dual-leg reclaims emit two). */
  readonly reclaims: readonly ReclaimedEvent[]
}

/**
 * Waits for a transaction receipt, verifies it succeeded, and decodes all
 * Omnibus events it emitted.
 *
 * @param publicClient - The Viem public client to poll through.
 * @param hash - The transaction hash returned by a write method.
 * @param options - Confirmation count and timeout; pick these per your
 *   finality policy — one confirmation on a reorg-prone chain is weak
 *   evidence.
 * @returns The typed {@link OmnibusReceipt}.
 * @throws QuipSwapError `TRANSACTION_REVERTED` when the receipt status is
 *   `'reverted'`; `CONTRACT_REVERT` (with `cause`) when waiting itself
 *   fails (timeout, replacement, RPC error).
 * @example
 * ```ts
 * const hash = await client.commit({lock, party, counterparty})
 * const {commitments} = await waitForOmnibusReceipt(publicClient, hash, {confirmations: 3})
 * console.log(commitments[0]?.lock)
 * ```
 */
export async function waitForOmnibusReceipt(
  publicClient: PublicClient,
  hash: Hash,
  options: WaitOptions = {},
): Promise<OmnibusReceipt> {
  let receipt: TransactionReceipt
  try {
    receipt = await publicClient.waitForTransactionReceipt({
      hash,
      ...(options.confirmations !== undefined ? {confirmations: options.confirmations} : {}),
      ...(options.timeout !== undefined ? {timeout: options.timeout} : {}),
    })
  } catch (error) {
    throw wrapContractError(error, `Waiting for receipt of ${hash}`)
  }

  if (receipt.status !== 'success') {
    throw new QuipSwapError({
      code: 'TRANSACTION_REVERTED',
      message: `Transaction ${hash} was mined but reverted`,
      details: {receipt},
    })
  }

  return {
    transactionHash: hash,
    receipt,
    commitments: decodeCommitmentEvents(receipt.logs),
    claims: decodeClaimEvents(receipt.logs),
    reclaims: decodeReclaimedEvents(receipt.logs),
  }
}
