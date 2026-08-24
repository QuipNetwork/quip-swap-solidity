/**
 * Receipt helpers.
 *
 * A returned transaction hash is NOT confirmation: the transaction may
 * still be pending, may revert, or may be dropped/replaced. These helpers
 * wait for a receipt, check `status`, and decode the relevant Omnibus
 * events into typed results.
 *
 * Address-scoped decoding: when `options.address` is supplied, only logs
 * emitted by that address are decoded — preventing another contract in the
 * same transaction from emitting an Omnibus-shaped `Commitment`/`Claim`/
 * `Reclaimed` event that the receipt helper would otherwise decode as
 * genuine. Prefer the client-bound {@link OmnibusClient.waitForReceipt},
 * which passes the client's Omnibus address automatically. Omitting
 * `address` keeps the legacy raw behavior (decode every matching log) for
 * backward compatibility, but is NOT recommended for security-sensitive
 * flows.
 *
 * Submission ({@link OmnibusClient.commit} et al.) and receipt waiting are
 * deliberately separate so the application chooses its own confirmation
 * count, timeout, retry, and finality policy per call.
 */
import type {Address, Hash, Log, PublicClient, TransactionReceipt} from 'viem'
import {QuipSwapError, wrapContractError} from './errors.js'
import {decodeClaimEvents, decodeCommitmentEvents, decodeReclaimedEvents} from './events.js'
import type {ClaimEvent, CommitmentEvent, ReclaimedEvent} from './events.js'

/** Options forwarded to `publicClient.waitForTransactionReceipt`, plus address scoping. */
export interface WaitOptions {
  /**
   * The expected Omnibus contract address. When set, only logs emitted by
   * this address are decoded into `commitments`/`claims`/`reclaims` — the
   * defense against same-signature events from other contracts in the same
   * transaction. Omitting it decodes every matching log (legacy behavior;
   * not recommended). {@link OmnibusClient.waitForReceipt} fills this in.
   */
  readonly address?: Address
  /** Number of confirmations to wait for (default: the client's default, 1). */
  readonly confirmations?: number
  /** Milliseconds to wait before giving up. */
  readonly timeout?: number
}

/**
 * Returns only the logs emitted by `address` (case-insensitive). When
 * `address` is undefined, returns `logs` unchanged (legacy raw behavior).
 */
function filterLogsByAddress(logs: readonly Log[], address?: Address): readonly Log[] {
  if (address === undefined) return logs
  const expected = address.toLowerCase()
  return logs.filter(log => log.address.toLowerCase() === expected)
}

/** A successful, decoded Omnibus transaction result. */
export interface OmnibusReceipt {
  /** The transaction hash that was waited on. */
  readonly transactionHash: Hash
  /** The full Viem receipt (status is guaranteed `'success'`). */
  readonly receipt: TransactionReceipt
  /** Decoded `Commitment` events emitted by the transaction (0 or 1). */
  readonly commitments: readonly CommitmentEvent[]
  /** Decoded `Claim` events (0, 1, or 2 — a same-chain claim emits one per recipient leg). */
  readonly claims: readonly ClaimEvent[]
  /** Decoded `Reclaimed` events (0 or 1 — each reclaim settles one side's own leg). */
  readonly reclaims: readonly ReclaimedEvent[]
}

/**
 * Waits for a transaction receipt, verifies it succeeded, and decodes all
 * Omnibus events it emitted.
 *
 * @param publicClient - The Viem public client to poll through.
 * @param hash - The transaction hash returned by a write method.
 * @param options - `address` (strongly recommended — scopes decoding to the
 *   Omnibus deployment; see {@link WaitOptions}), plus confirmation count
 *   and timeout. Pick confirmations per your finality policy — one
 *   confirmation on a reorg-prone chain is weak evidence.
 * @returns The typed {@link OmnibusReceipt}; `commitments`/`claims`/
 *   `reclaims` contain only events from `options.address` when supplied.
 * @throws QuipSwapError `TRANSACTION_REVERTED` when the receipt status is
 *   `'reverted'`; `CONTRACT_REVERT` (with `cause`) when waiting itself
 *   fails (timeout, replacement, RPC error).
 * @example
 * ```ts
 * // prefer client.waitForReceipt; standalone form must pass the address:
 * const hash = await client.commit({lock, party, counterparty})
 * const {commitments} = await waitForOmnibusReceipt(publicClient, hash, {
 *   address: omnibusAddress,
 *   confirmations: 3,
 * })
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

  // scope to the expected Omnibus address (when given) BEFORE decoding, so a
  // same-signature event from another contract in this tx is never decoded
  // as a genuine Omnibus event
  const logs = filterLogsByAddress(receipt.logs, options.address)

  return {
    transactionHash: hash,
    receipt,
    commitments: decodeCommitmentEvents(logs),
    claims: decodeClaimEvents(logs),
    reclaims: decodeReclaimedEvents(logs),
  }
}
