/**
 * Same-chain swap workflow helpers.
 *
 * Roles: the PROPOSER is the side with the earlier schedule (smaller
 * `commitmentDeadline`) and commits first; the TAKER commits second. The
 * SECRET HOLDER must be the proposer: only the proposer can claim in the
 * first claim window, so giving the secret to the taker would invert the
 * protocol's risk model.
 *
 * The happy path (all windows half-open `[lower, upper)`):
 *
 * ```text
 * 1. Build both sides' terms with a strictly interleaved schedule.
 * 2. The proposer generates the secret and lock.
 * 3. Proposer commits in [0, proposer.commitmentDeadline)    -> lock Free
 * 4. WAIT: the taker's window opens only at proposer.commitmentDeadline.
 * 5. Taker commits in [proposer.commit, taker.commit)        -> lock Committed
 *    (the taker posts the OTHER side; re-posting reverts TermsAlreadyPosted)
 * 6. Anyone with the secret claims in [taker.commit, proposer.claim)
 *    — ONE claim settles BOTH legs                           -> lock Spent
 * ```
 *
 * Unhappy paths: reclaim from `Free` (only the proposer committed) is valid
 * once the proposer's `reclaimRelease` passes; reclaim from `Committed`
 * returns BOTH legs in one transaction when the counterparty leg is local.
 *
 * These helpers never hide wallet signing, never auto-approve, and never
 * submit transactions on their own — every transaction is an explicit
 * application call. Status inspection combines actual on-chain state
 * (`lockState`, `posted`, `termsHash`) with the current window.
 *
 * Schedule validation — including gap-SIZE buffers — happens in
 * {@link planSameChainSwap}. The contract checks interleaving ORDER but
 * never gap size, so this is the only place a dangerously tight same-chain
 * window is caught. There is nothing forcing it (unlike the cross-chain
 * flow's reaction handoff), so BOTH parties should run `planSameChainSwap`
 * on their own terms before acting — it is per-party self-protection.
 */
import {DEFAULT_SAME_CHAIN_BUFFER_SECONDS, checkScheduleBuffers} from '../buffers.js'
import {digestTerms, digestTermsCanonically} from '../hashing.js'
import {proposedBy, validateTermPairing, validateTerms} from '../terms.js'
import {LockState} from '../types.js'
import type {Hex32, Terms} from '../types.js'
import {
  isWithinWindow,
  proposerClaimWindow,
  proposerCommitWindow,
  reclaimWindow,
  takerClaimWindow,
  takerCommitWindow,
} from '../windows.js'
import type {TimeWindow} from '../windows.js'
import type {OmnibusClient} from '../client.js'
import {QuipSwapError} from '../errors.js'

/**
 * A validated same-chain swap plan with both sides normalized into
 * proposer/taker roles and all five action windows precomputed.
 */
export interface SameChainSwapPlan {
  /** The proposer's terms (earlier schedule; commits first; holds the secret). */
  readonly proposerTerms: Terms
  /** The taker's terms (later schedule; commits second). */
  readonly takerTerms: Terms
  /** The canonical trade digest stored in `termsHash[lock]` on commit. */
  readonly canonicalDigest: Hex32
  /** The proposer side's single-terms digest (its `posted` key). */
  readonly proposerDigest: Hex32
  /** The taker side's single-terms digest (its `posted` key). */
  readonly takerDigest: Hex32
  /** `[0, proposer.commitmentDeadline)`. */
  readonly proposerCommitWindow: TimeWindow
  /** `[proposer.commitmentDeadline, taker.commitmentDeadline)`. */
  readonly takerCommitWindow: TimeWindow
  /** `[taker.commitmentDeadline, proposer.claimDeadline)` — one claim settles both legs. */
  readonly claimWindow: TimeWindow
  /** `[proposer.reclaimRelease, +inf)` for the proposer's leg. */
  readonly proposerReclaimWindow: TimeWindow
  /** `[taker.reclaimRelease, +inf)` for the taker's leg. */
  readonly takerReclaimWindow: TimeWindow
}

/**
 * Validates a same-chain pairing and assembles a {@link SameChainSwapPlan}.
 *
 * Validates structure, interleaving (ORDER), that both sides name the SAME
 * chain, AND the gap-SIZE buffers between adjacent schedule timestamps.
 * Accepts the two sides in either order; roles are derived from the
 * schedule (`proposedBy`). Use {@link validateCrossChainSchedule} for
 * cross-chain swaps.
 *
 * The CONTRACT does not check buffer sizes — it only enforces interleaving
 * order — so this is the ONLY place a dangerously tight same-chain window is
 * caught. And nothing forces it (unlike the cross-chain reaction handoff):
 * BOTH parties should call `planSameChainSwap` on their own terms before
 * acting. It is per-party self-protection, not a shared gate.
 *
 * @param a - One side's terms.
 * @param b - The other side's terms.
 * @param opts - Optional. `minimumBufferSeconds` sets the minimum acceptable
 *   gap (seconds) between every adjacent pair of schedule timestamps;
 *   defaults to {@link DEFAULT_SAME_CHAIN_BUFFER_SECONDS} when omitted.
 *   Overriding BELOW the default may let dangerously tight windows through —
 *   only do so if you understand your chain's finality.
 * @returns The normalized plan with windows and digests precomputed.
 * @throws QuipSwapError - structural codes from {@link validateTerms};
 *   `DISORDERED_DEADLINES` for a non-interleaved schedule;
 *   `CHAIN_ID_MISMATCH` when the sides name different chains;
 *   `INSUFFICIENT_BUFFER` when any adjacent gap is below the minimum.
 * @see TermsLib.validateTermPairing, checkScheduleBuffers
 * @example
 * ```ts
 * const plan = planSameChainSwap(aliceTerms, bobTerms) // default buffer
 * // proposer commits first:
 * await client.commit({lock, party: plan.proposerTerms, counterparty: plan.takerTerms})
 * ```
 */
export function planSameChainSwap(
  a: Terms,
  b: Terms,
  opts?: {readonly minimumBufferSeconds?: bigint},
): SameChainSwapPlan {
  validateTerms(a)
  validateTerms(b)
  validateTermPairing(a, b)
  if (a.chainId !== b.chainId) {
    throw new QuipSwapError({
      code: 'CHAIN_ID_MISMATCH',
      message: `Same-chain plan requires both sides on one chain; got ${a.chainId} and ${b.chainId}`,
      details: {aChainId: a.chainId, bChainId: b.chainId},
    })
  }
  const [proposerTerms, takerTerms] = proposedBy(a, b) === 'party' ? [a, b] : [b, a]
  // gap-SIZE buffer check (the contract never does this) — the new protection
  checkScheduleBuffers(proposerTerms, takerTerms, opts?.minimumBufferSeconds ?? DEFAULT_SAME_CHAIN_BUFFER_SECONDS)
  return {
    proposerTerms,
    takerTerms,
    canonicalDigest: digestTermsCanonically(proposerTerms, takerTerms),
    proposerDigest: digestTerms(proposerTerms),
    takerDigest: digestTerms(takerTerms),
    proposerCommitWindow: proposerCommitWindow(proposerTerms),
    takerCommitWindow: takerCommitWindow(takerTerms, proposerTerms),
    claimWindow: proposerClaimWindow(proposerTerms, takerTerms),
    proposerReclaimWindow: reclaimWindow(proposerTerms),
    takerReclaimWindow: reclaimWindow(takerTerms),
  }
}

/**
 * Application-level swap status — deliberately SEPARATE from the Solidity
 * {@link LockState}: the chain knows four states, but an application also
 * needs to know which window is open and which side has posted.
 */
export type SameChainSwapStatus =
  /** Nothing committed; the proposer's commit window is open. */
  | 'awaiting-proposer-commit'
  /**
   * Nothing committed and the proposer's window has closed. The swap can
   * no longer COMPLETE (the proposer can never commit, so the lock can
   * never reach Committed) — but the contract will still accept a
   * taker-first commit in `[proposer.commitmentDeadline,
   * taker.commitmentDeadline)`: `Omnibus.commit` checks only the window,
   * not that the proposer actually committed (verifying the counterparty's
   * commitment is the committer's duty, per the contract comments). Such a
   * commit is pointless and self-harming — it moves the lock Unused→Free
   * and strands the taker's assets until `taker.reclaimRelease` (reclaim
   * from Free). Treat this status as terminal and do NOT commit into it.
   */
  | 'proposer-commit-expired'
  /** Proposer committed (lock Free); the taker's window has not opened yet. */
  | 'awaiting-taker-window'
  /** Proposer committed (lock Free); the taker's window is open. */
  | 'awaiting-taker-commit'
  /** Only the proposer committed and the taker's window closed; awaiting the proposer's reclaimRelease. */
  | 'half-committed-expired'
  /** Both committed before the taker's commitment deadline; the proposer-claim window has not opened yet. */
  | 'awaiting-claim-window'
  /** Both committed; the claim window is open — the secret holder should claim. */
  | 'claimable'
  /** Both committed; the proposer-claim window closed (taker-claim window may run until proposer.reclaimRelease). */
  | 'late-claimable'
  /** Both committed; no claim landed and a leg's reclaim window is open. */
  | 'reclaimable'
  /** Lock Free and the proposer's reclaim window is open (reclaim-from-Free). */
  | 'reclaimable-from-free'
  /** Terminal: the lock is Spent (claimed or reclaimed). */
  | 'settled'

/** The full status report returned by {@link getSameChainSwapStatus}. */
export interface SameChainSwapStatusReport {
  /** The application-level status (see {@link SameChainSwapStatus}). */
  readonly status: SameChainSwapStatus
  /** The raw on-chain {@link LockState} the status was derived from. */
  readonly lockState: LockState
  /** Whether the proposer's side is posted on-chain. */
  readonly proposerPosted: boolean
  /** Whether the taker's side is posted on-chain. */
  readonly takerPosted: boolean
  /** The chain timestamp the report was computed at. */
  readonly timestamp: bigint
}

/**
 * Inspects a same-chain swap's status from ACTUAL on-chain state
 * (`lockState`, `posted`) combined with the current block timestamp.
 *
 * @param client - An {@link OmnibusClient} on the swap's chain.
 * @param lock - The swap's hashlock.
 * @param plan - The plan from {@link planSameChainSwap}.
 * @returns A {@link SameChainSwapStatusReport}; never throws on unexpected
 *   state combinations — the raw fields are included so the application can
 *   inspect them.
 * @example
 * ```ts
 * const {status} = await getSameChainSwapStatus(client, lock, plan)
 * if (status === 'claimable') await client.claim({secret, party: plan.proposerTerms, counterparty: plan.takerTerms})
 * ```
 */
export async function getSameChainSwapStatus(
  client: OmnibusClient,
  lock: Hex32,
  plan: SameChainSwapPlan,
): Promise<SameChainSwapStatusReport> {
  const [state, proposerPosted, takerPosted, block] = await Promise.all([
    client.getLockState(lock),
    client.getPosted(lock, plan.proposerDigest),
    client.getPosted(lock, plan.takerDigest),
    client.publicClient.getBlock(),
  ])
  const timestamp = block.timestamp

  let status: SameChainSwapStatus
  switch (state) {
    case LockState.Unused:
      status = isWithinWindow(plan.proposerCommitWindow, timestamp)
        ? 'awaiting-proposer-commit'
        : 'proposer-commit-expired'
      break
    case LockState.Free:
      if (isWithinWindow(plan.proposerReclaimWindow, timestamp)) {
        // reclaim from Free: a half-committed swap is recoverable once the
        // committed leg's release passes (Free -> Spent is a valid transition)
        status = 'reclaimable-from-free'
      } else if (timestamp < plan.takerCommitWindow.lower) {
        status = 'awaiting-taker-window'
      } else if (isWithinWindow(plan.takerCommitWindow, timestamp)) {
        status = 'awaiting-taker-commit'
      } else {
        status = 'half-committed-expired'
      }
      break
    case LockState.Committed:
      if (isWithinWindow(plan.claimWindow, timestamp)) {
        status = 'claimable'
      } else if (isWithinWindow(plan.proposerReclaimWindow, timestamp)) {
        status = 'reclaimable'
      } else if (timestamp >= plan.proposerTerms.claimDeadline) {
        // between proposer.claimDeadline and proposer.reclaimRelease the
        // taker-role claim path is still open (it settles both legs too)
        status = 'late-claimable'
      } else {
        // Committed before taker.commitmentDeadline: the taker committed
        // early in its window; the proposer-claim window opens at
        // taker.commitmentDeadline
        status = 'awaiting-claim-window'
      }
      break
    case LockState.Spent:
      status = 'settled'
      break
  }

  return {status, lockState: state, proposerPosted, takerPosted, timestamp}
}
