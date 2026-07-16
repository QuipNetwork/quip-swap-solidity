/**
 * Schedule buffer defaults and the shared gap-size check.
 *
 * A swap's six lifecycle timestamps must do two distinct things:
 * - **ORDER** — strictly interleave (proposer first at every stage). The
 *   contract enforces this on every commit (`TermsLib.validateTermPairing`),
 *   and the SDK mirrors it in `validateTermPairing`.
 * - **SIZE** — leave enough wall-clock time between adjacent stages for each
 *   party to act and react. The contract does NOT check gap size, so the SDK
 *   is the ONLY place a dangerously tight window can be caught.
 *
 * This module owns the SIZE check. The gaps protect the action/reaction
 * windows against chain finality, reorg risk, RPC outages, network
 * congestion, and relayer latency — most critically the taker's post-reveal
 * reaction buffer (`proposer.reclaimRelease - proposer.claimDeadline`).
 *
 * OPTIMISTIC pairings get the SAME buffer treatment. Optimistic mode waives
 * only the commit/claim LOWER bounds (the waits); the deadlines themselves
 * remain the timed FALLBACK schedule if the fast path stalls, and the
 * reaction buffer remains the surviving theft prevention (reclaimRelease is
 * never waived). Generous gaps are therefore just as important — never tune
 * a schedule tight because the happy path is expected to settle instantly.
 *
 * The {@link DEFAULT_BUFFERS} presets are conservative STARTING POINTS keyed
 * to a chain's finality profile, not authoritative values — tune them to the
 * chains you actually operate on.
 */
import {QuipSwapError} from './errors.js'
import type {Terms} from './types.js'

/**
 * Suggested minimum-buffer presets (seconds) by chain-finality profile.
 * Starting points to tune to your chains, NOT authoritative values.
 *
 * - `fastL2` (~5 min): fast-finality L2s with low reorg risk.
 * - `standard` (~30 min): general-purpose default.
 * - `conservativeL1` (~1 hr): congested or deep-reorg-risk L1s.
 */
export const DEFAULT_BUFFERS = {
  /** ~5 min — fast-finality L2s. */
  fastL2: 300n,
  /** ~30 min — general default. */
  standard: 1800n,
  /** ~1 hr — congested / deep-reorg-risk L1s. */
  conservativeL1: 3600n,
} as const

/**
 * Default minimum buffer applied to CROSS-CHAIN schedules when the caller
 * supplies none. A conservative starting point ({@link DEFAULT_BUFFERS}.standard,
 * ~30 min) — tune to your chains; overriding BELOW it can expose users to
 * missed windows and lost funds under congestion/reorgs.
 */
export const DEFAULT_CROSS_CHAIN_BUFFER_SECONDS = DEFAULT_BUFFERS.standard

/**
 * Default minimum buffer applied to SAME-CHAIN schedules when the caller
 * supplies none. Same conservative starting point as the cross-chain default
 * ({@link DEFAULT_BUFFERS}.standard, ~30 min) but a SEPARATE constant so the
 * two modes can be tuned independently later without touching call sites.
 */
export const DEFAULT_SAME_CHAIN_BUFFER_SECONDS = DEFAULT_BUFFERS.standard

/**
 * Validates that every adjacent gap in a pairing's interleaved six-timestamp
 * schedule is at least `minimumBufferSeconds`. This is the gap-SIZE check
 * (distinct from interleaving ORDER, validated by `validateTermPairing`);
 * the contract never checks size, so this is the only enforcement point.
 *
 * The schedule order checked is: `proposer.commitmentDeadline`,
 * `taker.commitmentDeadline`, `proposer.claimDeadline`, `taker.claimDeadline`,
 * `proposer.reclaimRelease`, `taker.reclaimRelease`. Callers must pass terms
 * whose roles are already normalized (proposer = smaller `commitmentDeadline`).
 *
 * @param proposerTerms - The proposer's leg (smaller `commitmentDeadline`).
 * @param takerTerms - The taker's leg.
 * @param minimumBufferSeconds - The minimum acceptable gap (seconds) between
 *   every adjacent pair of schedule timestamps.
 * @returns `{minimumGapSeconds}` — the smallest adjacent gap in the schedule.
 * @throws QuipSwapError `INSUFFICIENT_BUFFER` when any adjacent gap is below
 *   `minimumBufferSeconds` (details carry the offending pair and the gap).
 * @see TermsLib.validateTermPairing (the ORDER check this complements)
 * @example
 * ```ts
 * const {minimumGapSeconds} = checkScheduleBuffers(proposer, taker, 1800n)
 * ```
 */
export function checkScheduleBuffers(
  proposerTerms: Terms,
  takerTerms: Terms,
  minimumBufferSeconds: bigint,
): {minimumGapSeconds: bigint} {
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

  return {minimumGapSeconds: minimumGapSeconds ?? 0n}
}
