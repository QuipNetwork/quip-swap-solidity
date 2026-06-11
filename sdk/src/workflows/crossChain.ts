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
import {QuipSwapError} from '../errors.js'
import {digestTerms, digestTermsCanonically, generateLock} from '../hashing.js'
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
   * No production-safe default exists, so this parameter is REQUIRED.
   * Choose it from: chain finality, reorg risk, RPC reliability, network
   * congestion, relayer responsiveness, and your operational safety
   * margin. A value that is comfortable on a fast-finality L2 may be
   * recklessly small on a congested L1.
   */
  readonly minimumBufferSeconds: bigint
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
 *    including the reaction buffer — is at least `minimumBufferSeconds`.
 *
 * @param args - See {@link ValidateCrossChainScheduleArgs}; parameter names
 *   are protocol roles (`proposerTerms`/`takerTerms`), not call-site roles.
 * @returns The {@link CrossChainSchedule} summary (buffers included).
 * @throws QuipSwapError - structural codes; `DISORDERED_DEADLINES`;
 *   `SECRET_HOLDER_NOT_PROPOSER` when the roles are inverted;
 *   `CHAIN_ID_MISMATCH` when both legs share a chain;
 *   `INSUFFICIENT_BUFFER` when any adjacent gap is below the minimum.
 * @see TermsLib.validateTermPairing, test/attack/CrossChainFreeOption.t.sol
 * @example
 * ```ts
 * const schedule = validateCrossChainSchedule({
 *   proposerTerms: aliceTermsOnChainA, // Alice holds the secret
 *   takerTerms: bobTermsOnChainB,
 *   minimumBufferSeconds: 1800n, // your finality/ops margin — no safe default
 * })
 * ```
 */
export function validateCrossChainSchedule(args: ValidateCrossChainScheduleArgs): CrossChainSchedule {
  const {proposerTerms, takerTerms, minimumBufferSeconds} = args
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

  // the six interleaved timestamps, in schedule order
  const sequence: readonly [string, bigint][] = [
    ['proposer.commitmentDeadline', proposerTerms.commitmentDeadline],
    ['taker.commitmentDeadline', takerTerms.commitmentDeadline],
    ['proposer.claimDeadline', proposerTerms.claimDeadline],
    ['taker.claimDeadline', takerTerms.claimDeadline],
    ['proposer.reclaimRelease', proposerTerms.reclaimRelease],
    ['taker.reclaimRelease', takerTerms.reclaimRelease],
  ]

  let minimumGapSeconds: bigint | undefined
  for (let i = 1; i < sequence.length; i++) {
    const [prevName, prev] = sequence[i - 1] as [string, bigint]
    const [nextName, next] = sequence[i] as [string, bigint]
    const gap = next - prev
    if (gap < minimumBufferSeconds) {
      throw new QuipSwapError({
        code: 'INSUFFICIENT_BUFFER',
        message:
          `Gap between ${prevName} (${prev}) and ${nextName} (${next}) is ${gap}s, below the required ` +
          `minimum of ${minimumBufferSeconds}s. Every adjacent gap — especially the taker's post-reveal ` +
          'reaction buffer (proposer.reclaimRelease - proposer.claimDeadline) — must cover finality, reorg ' +
          'risk, RPC outages, congestion, and relayer latency',
        details: {prevName, prev, nextName, next, gap, minimumBufferSeconds},
      })
    }
    if (minimumGapSeconds === undefined || gap < minimumGapSeconds) minimumGapSeconds = gap
  }

  return {
    proposerTerms,
    takerTerms,
    // reactionBuffer = proposer.reclaimRelease - proposer.claimDeadline
    reactionBufferSeconds: proposerTerms.reclaimRelease - proposerTerms.claimDeadline,
    minimumGapSeconds: minimumGapSeconds ?? 0n,
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
 * The contract states this obligation explicitly (`Omnibus.commit`: "the
 * party MUST ensure the commitment from the counterparty has taken effect
 * especially if the swap is cross-chain") — it cannot be enforced on-chain
 * because Chain B cannot read Chain A. A taker that commits without this
 * check risks escrowing assets against a proposer who never committed.
 *
 * Finality caveat: a `true` result reflects the remote chain at query
 * time. Apply your own confirmation depth (re-check after N blocks) before
 * relying on it; a reorg can undo a young commitment.
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
  const [state, proposerPosted, onChainTermsHash] = await Promise.all([
    remoteClient.getLockState(lock),
    remoteClient.getPosted(lock, digestTerms(proposerTerms)),
    remoteClient.getTermsHash(lock),
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
