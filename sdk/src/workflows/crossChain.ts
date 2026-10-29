/**
 * Cross-chain swap workflow helpers.
 *
 * A cross-chain swap is NOT atomic: it is a coordinated flow across two
 * independent EVM chains. The strictly interleaved six-timestamp schedule
 * plus one MANDATORY off-chain check are what bound each side's risk.
 *
 * Roles and timing are identical to the same-chain flow — one shared
 * schedule — but each leg lives on its own chain and each local commit
 * moves that chain's lock `Unused -> Committed` directly (no `Free` state
 * cross-chain). With Alice the proposer/secret holder on Chain A and Bob
 * the taker on Chain B:
 *
 * ```text
 * 1. Alice generates the secret and lock.
 * 2. Alice commits her leg on Chain A in [0, alice.commitmentDeadline).
 * 3. Bob VERIFIES ALICE'S CHAIN-A COMMITMENT OFF-CHAIN (mandatory — the
 *    Chain B contract cannot see Chain A), then commits on Chain B in
 *    [alice.commitmentDeadline, bob.commitmentDeadline).
 * 4. Alice claims Bob's leg ON CHAIN B in [bob.commitmentDeadline,
 *    alice.claimDeadline) — claim(secret, party=alice, counterparty=bob).
 *    The Chain B Claim event reveals the secret.
 * 5. Bob (or a relayer) extracts the secret from the Chain B Claim event.
 * 6. Bob claims Alice's leg ON CHAIN A in [alice.claimDeadline,
 *    alice.reclaimRelease) — claim(secret, party=bob, counterparty=alice).
 * 7. Both locks are Spent.
 * ```
 *
 * THE SECRET HOLDER MUST BE THE PROPOSER. If the secret holder were the
 * taker, the windows would let them claim the counterparty's leg while
 * retaining the option to let their own leg expire — the cross-chain
 * "free option" the interleaving exists to prevent (see
 * `test/attack/CrossChainFreeOption.t.sol`).
 */
import {DEFAULT_CROSS_CHAIN_BUFFER_SECONDS, checkScheduleBuffers} from '../buffers.js'
import {QuipSwapError} from '../errors.js'
import {digestTerms, digestTermsCanonically, generateLock, swapId} from '../hashing.js'
import {proposedBy, validateTermPairing, validateTerms} from '../terms.js'
import {LockState} from '../types.js'
import type {Hex32, Terms} from '../types.js'
import type {OmnibusClient} from '../client.js'

/** Arguments for {@link validateCrossChainSchedule}. */
export interface ValidateCrossChainScheduleArgs {
  /**
   * The SECRET HOLDER's leg. The secret holder must be the proposer (the
   * side with the smaller `commitmentDeadline`); anything else is the
   * free-option misconfiguration and is rejected.
   */
  readonly proposerTerms: Terms
  /** The counterparty's (taker's) leg, on the other chain. */
  readonly takerTerms: Terms
  /**
   * Minimum acceptable gap, in SECONDS, between EVERY pair of adjacent
   * timestamps in the interleaved schedule — including the taker's
   * post-reveal reaction buffer
   * (`proposer.reclaimRelease - proposer.claimDeadline`).
   *
   * Optional: defaults to {@link DEFAULT_CROSS_CHAIN_BUFFER_SECONDS} when
   * omitted. Choose it from chain finality, reorg risk, RPC reliability,
   * network congestion, relayer responsiveness, and your operational safety
   * margin (the {@link DEFAULT_BUFFERS} presets are starting points). A
   * value comfortable on a fast-finality L2 may be recklessly small on a
   * congested L1. Overriding BELOW the default can expose users to missed
   * windows and lost funds under congestion/reorgs — only do so if you
   * understand your chains' finality.
   */
  readonly minimumBufferSeconds?: bigint
  /**
   * The maximum plausible CLOCK SKEW, in SECONDS, between the two chains'
   * block timestamps — the amount by which the taker's chain may lag (or
   * the proposer's chain may run ahead of) wall-clock relative to each other.
   *
   * Cross-chain, the six timestamps are NOT judged against one clock. Each
   * side's windows are enforced against its own chain's `block.timestamp`,
   * and the taker's reaction buffer is the ONE gap that straddles both: the
   * secret is revealed when the proposer claims on the TAKER's chain, but the
   * taker's own claim window CLOSES on the PROPOSER's chain at
   * `proposer.reclaimRelease`. If the proposer's chain runs ahead, that close
   * arrives early in wall-clock and eats into the reaction window — a large
   * enough skew can shut it before the revealed secret is even usable, letting
   * the proposer collect the taker's leg and reclaim its own. Sequencer-set L2
   * timestamps can deviate from wall-clock, and no two chains share a clock.
   *
   * Optional, defaults to `0n` (no skew allowance — preserves prior behavior).
   * When set, the taker's reaction buffer
   * (`proposer.reclaimRelease - proposer.claimDeadline`) must exceed the
   * operational buffer by AT LEAST this much, i.e. be at least
   * `minimumBufferSeconds + maxClockSkewSeconds`; otherwise validation throws
   * `INSUFFICIENT_REACTION_BUFFER`. Set it to the worst-case skew you are
   * willing to tolerate for THIS chain pair — operational slack and skew are
   * independent hazards that both consume the same reaction window.
   */
  readonly maxClockSkewSeconds?: bigint
}

/** The validated cross-chain schedule summary. */
export interface CrossChainSchedule {
  /** The proposer's (secret holder's) leg. */
  readonly proposerTerms: Terms
  /** The taker's leg. */
  readonly takerTerms: Terms
  /**
   * The taker's post-reveal reaction buffer in seconds:
   * `proposer.reclaimRelease - proposer.claimDeadline` — the gap between
   * the latest possible secret reveal (the proposer-claim window closes at
   * `proposer.claimDeadline`) and the close of the taker's claim window
   * (`proposer.reclaimRelease`). This is the taker's time to observe the
   * revealed secret and land their own claim.
   */
  readonly reactionBufferSeconds: bigint
  /** The smallest gap between any two adjacent schedule timestamps, in seconds. */
  readonly minimumGapSeconds: bigint
}

/**
 * Validates a cross-chain swap schedule before any transaction is sent.
 *
 * Checks, in order:
 * 1. Both terms are structurally valid and the pairing strictly
 *    interleaves (the contract enforces this on BOTH chains; the SDK
 *    rejects bad pairings before any gas is spent).
 * 2. The secret holder's leg (`proposerTerms`) actually IS the proposer —
 *    rejecting the free-option role mis-assignment.
 * 3. The two legs are on DIFFERENT chains (use {@link planSameChainSwap}
 *    otherwise).
 * 4. Every gap between adjacent timestamps in the interleaved schedule —
 *    including the reaction buffer — is at least `minimumBufferSeconds`
 *    (defaults to {@link DEFAULT_CROSS_CHAIN_BUFFER_SECONDS} when omitted).
 * 5. The taker's reaction buffer additionally covers the chain pair's clock
 *    skew: it is at least `minimumBufferSeconds + maxClockSkewSeconds` (the
 *    reaction buffer is the only gap judged across both chains' clocks). With
 *    the default `maxClockSkewSeconds` of `0n` this adds no constraint.
 *
 * This validates the SCHEDULE only (interleaving, roles, buffers) and reads
 * no chain — it is NOT proof that any party has committed. A taker must
 * still run {@link verifyRemoteCommitment} against the proposer's chain
 * before committing; a valid schedule alone does not make a commit safe.
 *
 * @param args - See {@link ValidateCrossChainScheduleArgs}; parameter names
 *   are protocol roles (`proposerTerms`/`takerTerms`), not call-site roles.
 * @returns The {@link CrossChainSchedule} summary (buffers included).
 * @throws QuipSwapError - structural codes; `DISORDERED_DEADLINES`;
 *   `SECRET_HOLDER_NOT_PROPOSER` when the roles are inverted;
 *   `CHAIN_ID_MISMATCH` when both legs share a chain;
 *   `INSUFFICIENT_BUFFER` when any adjacent gap is below the minimum;
 *   `INSUFFICIENT_REACTION_BUFFER` when the taker's reaction buffer does not
 *   also cover `maxClockSkewSeconds` on top of the operational buffer.
 * @see TermsLib.validateTermPairing, test/attack/CrossChainFreeOption.t.sol
 * @example
 * ```ts
 * const schedule = validateCrossChainSchedule({
 *   proposerTerms: aliceTermsOnChainA, // Alice holds the secret
 *   takerTerms: bobTermsOnChainB,
 *   // minimumBufferSeconds omitted → DEFAULT_CROSS_CHAIN_BUFFER_SECONDS;
 *   // or pass an explicit margin, e.g. DEFAULT_BUFFERS.conservativeL1
 * })
 * ```
 */
export function validateCrossChainSchedule(args: ValidateCrossChainScheduleArgs): CrossChainSchedule {
  const {proposerTerms, takerTerms} = args
  const minimumBufferSeconds = args.minimumBufferSeconds ?? DEFAULT_CROSS_CHAIN_BUFFER_SECONDS
  const maxClockSkewSeconds = args.maxClockSkewSeconds ?? 0n
  validateTerms(proposerTerms)
  validateTerms(takerTerms)
  validateTermPairing(proposerTerms, takerTerms)

  // SECURITY: the secret holder must be the proposer. proposedBy returns
  // 'party' iff the first argument has the smaller commitmentDeadline.
  if (proposedBy(proposerTerms, takerTerms) !== 'party') {
    throw new QuipSwapError({
      code: 'SECRET_HOLDER_NOT_PROPOSER',
      message:
        "The secret holder's leg must be the proposer (smaller commitmentDeadline). A secret-holding taker " +
        'could claim the counterparty leg while letting its own leg expire — the cross-chain free option. ' +
        'Swap the role assignment or rebuild the schedule',
      details: {
        proposerCommitmentDeadline: proposerTerms.commitmentDeadline,
        takerCommitmentDeadline: takerTerms.commitmentDeadline,
      },
    })
  }

  if (proposerTerms.chainId === takerTerms.chainId) {
    throw new QuipSwapError({
      code: 'CHAIN_ID_MISMATCH',
      message: `Cross-chain schedule requires the two legs on different chains; both are on ${proposerTerms.chainId}`,
      details: {chainId: proposerTerms.chainId},
    })
  }

  // gap-SIZE check across the interleaved schedule (shared with the
  // same-chain validator); throws INSUFFICIENT_BUFFER on a too-tight gap
  const {minimumGapSeconds} = checkScheduleBuffers(proposerTerms, takerTerms, minimumBufferSeconds)

  // CLOCK SKEW: the taker's reaction buffer is the ONE gap judged across both
  // chains' clocks — it opens on the taker chain (the proposer's reveal) and
  // closes on the proposer chain (`proposer.reclaimRelease`). checkScheduleBuffers
  // already guaranteed it covers `minimumBufferSeconds`; require it to ALSO
  // absorb the chain pair's clock skew on top (both hazards consume the same
  // window). With the default maxClockSkewSeconds of 0n this is a no-op.
  const reactionBufferSeconds = proposerTerms.reclaimRelease - proposerTerms.claimDeadline
  const requiredReactionBufferSeconds = minimumBufferSeconds + maxClockSkewSeconds
  if (reactionBufferSeconds < requiredReactionBufferSeconds) {
    throw new QuipSwapError({
      code: 'INSUFFICIENT_REACTION_BUFFER',
      message:
        "The taker's post-reveal reaction buffer (proposer.reclaimRelease - proposer.claimDeadline) is " +
        `${reactionBufferSeconds}s, below the required ${requiredReactionBufferSeconds}s ` +
        `(minimumBufferSeconds ${minimumBufferSeconds}s + maxClockSkewSeconds ${maxClockSkewSeconds}s). ` +
        "This is the only gap judged across BOTH chains' clocks — the secret reveals on the taker's chain " +
        "but the taker's claim window closes on the proposer's chain — so it must exceed the operational " +
        "buffer by at least the chain pair's clock skew, or a proposer-chain clock running ahead can shut " +
        'the window before the revealed secret is usable',
      details: {
        reactionBufferSeconds,
        requiredReactionBufferSeconds,
        minimumBufferSeconds,
        maxClockSkewSeconds,
      },
    })
  }

  return {
    proposerTerms,
    takerTerms,
    // reactionBuffer = proposer.reclaimRelease - proposer.claimDeadline
    reactionBufferSeconds,
    minimumGapSeconds,
  }
}

/** The result of {@link verifyRemoteCommitment}. */
export interface RemoteCommitmentStatus {
  /** True iff the remote lock is `Committed` AND the remote side's terms are posted. */
  readonly committed: boolean
  /** The remote lock's state. */
  readonly lockState: LockState
  /** Whether the remote (proposer) side's terms digest is posted for the lock. */
  readonly proposerPosted: boolean
  /** Whether the on-chain canonical termsHash matches the supplied pairing. */
  readonly termsHashMatches: boolean
}

/**
 * The taker's MANDATORY pre-commit check: verifies on the PROPOSER's chain
 * that the proposer's commitment has actually taken effect.
 *
 * ⚠️ Skipping this before a cross-chain TAKER commit is the single most
 * dangerous mistake you can make with this SDK. If the taker commits and
 * the proposer never committed, the proposer (who holds the secret) can
 * claim the taker's escrowed leg while risking nothing — the taker loses
 * its funds. The contract states the obligation explicitly (`Omnibus.commit`:
 * "the party MUST ensure the commitment from the counterparty has taken
 * effect especially if the swap is cross-chain") but CANNOT enforce it
 * cross-chain, because the taker's chain cannot read the proposer's chain.
 *
 * Not spoofable: this reads on-chain STORAGE (`lockState` / `posted` /
 * `termsHash`), not events, so a forged log cannot fake a commitment. But
 * the result is POINT-IN-TIME — a reorg can undo a young commit — so apply
 * your own confirmation depth (re-check after N blocks) before relying on a
 * `true` result.
 *
 * Chain-agnostic: pass a client bound to the PROPOSER's chain for a
 * cross-chain swap (the case that matters); passing the local client for a
 * same-chain swap merely duplicates a guard the contract already enforces.
 *
 * @param remoteClient - An {@link OmnibusClient} bound to the PROPOSER's chain.
 * @param lock - The shared hashlock.
 * @param proposerTerms - The proposer's (remote) leg.
 * @param takerTerms - The taker's (local) leg.
 * @returns A {@link RemoteCommitmentStatus}; commit only when `committed`
 *   is true and your confirmation policy is satisfied.
 * @see Omnibus.commit
 * @example
 * ```ts
 * const status = await verifyRemoteCommitment(chainAClient, lock, aliceTerms, bobTerms)
 * if (status.committed) await chainBClient.commit({lock, party: bobTerms, counterparty: aliceTerms})
 * ```
 */
export async function verifyRemoteCommitment(
  remoteClient: OmnibusClient,
  lock: Hex32,
  proposerTerms: Terms,
  takerTerms: Terms,
): Promise<RemoteCommitmentStatus> {
  const id = swapId(lock, proposerTerms, takerTerms)
  const [state, proposerPosted, onChainTermsHash] = await Promise.all([
    remoteClient.getLockState(id),
    remoteClient.getPosted(id, digestTerms(proposerTerms)),
    remoteClient.getTermsHash(id),
  ])
  const termsHashMatches =
    onChainTermsHash.toLowerCase() === digestTermsCanonically(proposerTerms, takerTerms).toLowerCase()
  return {
    // cross-chain local commits move Unused -> Committed directly
    committed: state === LockState.Committed && proposerPosted && termsHashMatches,
    lockState: state,
    proposerPosted,
    termsHashMatches,
  }
}

/**
 * Derives the lock from a secret for cross-chain coordination — re-export
 * of {@link generateLock} under a workflow-centric name so coordinators
 * depend only on this module.
 *
 * @param secret - The proposer's 32-byte secret.
 * @returns The shared lock used on BOTH chains.
 * @throws QuipSwapError `INVALID_HEX32` for malformed secrets.
 * @see Omnibus._generateLock
 */
export function deriveSharedLock(secret: Hex32): Hex32 {
  return generateLock(secret)
}
