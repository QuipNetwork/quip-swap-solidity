/**
 * Half-open timing-window math.
 *
 * The protocol partitions the swap timeline into HALF-OPEN windows
 * `[lower, upper)` and the contract enforces, per action, that
 * `block.timestamp` falls in the right one (`TermsLib.enforceWithin`).
 * The exclusive upper bound is deliberate: adjacent windows share a
 * boundary (one window's upper is the next window's lower), and exclusivity
 * guarantees exactly one window accepts the shared instant. Never treat the
 * upper bound as inclusive.
 *
 * All helpers are pure and take an explicit timestamp — they never read the
 * local wall clock, because the contract judges windows against
 * `block.timestamp`, not the client's clock. Off-chain window validation is
 * a preflight convenience; it never replaces on-chain enforcement.
 */
import {QuipSwapError} from './errors.js'
import {proposedBy} from './terms.js'
import type {Terms} from './types.js'

/** `type(uint256).max` — the open upper bound of the reclaim window. */
export const MAX_UINT256 = (1n << 256n) - 1n

/**
 * A half-open time window `[lower, upper)` in Unix seconds.
 */
export interface TimeWindow {
  /** Inclusive lower bound (Unix seconds). */
  readonly lower: bigint
  /** EXCLUSIVE upper bound (Unix seconds); `MAX_UINT256` means unbounded. */
  readonly upper: bigint
}

/**
 * Asserts `timestamp` lies within the half-open window `[lower, upper)`.
 *
 * Exact transcription of `TermsLib.enforceWithin`:
 *
 * ```solidity
 * if (lower >= upper) revert InvalidRange();
 * if (lower > timestamp || upper <= timestamp) revert WindowViolated();
 * ```
 *
 * The upper bound is EXCLUSIVE: `timestamp === upper` is rejected.
 *
 * @param lower - Inclusive lower bound (Unix seconds).
 * @param upper - Exclusive upper bound (Unix seconds).
 * @param timestamp - The instant to test (pass the chain's `block.timestamp`).
 * @throws QuipSwapError `INVALID_RANGE` when `lower >= upper` (degenerate
 *   window — contract: InvalidRange); `WINDOW_VIOLATED` when the timestamp
 *   is before `lower` or at/after `upper` (contract: WindowViolated).
 * @see TermsLib.enforceWithin
 * @example
 * ```ts
 * enforceWithin(0n, 1000n, 999n)  // ok
 * enforceWithin(0n, 1000n, 1000n) // throws WINDOW_VIOLATED (upper exclusive)
 * ```
 */
export function enforceWithin(
  lower: bigint,
  upper: bigint,
  timestamp: bigint): void {
  if (lower >= upper) {
    throw new QuipSwapError({
      code: 'INVALID_RANGE',
      message: `Degenerate window: lower (${lower}) must be strictly less than upper (${upper}) (contract: InvalidRange)`,
      details: {
        lower,
        upper,
        timestamp
      },
    })
  }
  if (lower > timestamp || upper <= timestamp) {
    throw new QuipSwapError({
      code: 'WINDOW_VIOLATED',
      message:
        `Timestamp ${timestamp} is outside the half-open window [${lower}, ${upper}) ` +
        '(contract: WindowViolated; the upper bound is exclusive)',
      details: {
        lower,
        upper,
        timestamp
      },
    })
  }
}

/**
 * Non-throwing variant of {@link enforceWithin}.
 *
 * @param window - The half-open window to test.
 * @param timestamp - The instant to test (Unix seconds).
 * @returns `true` iff `window.lower <= timestamp < window.upper` and the
 *   window is non-degenerate.
 */
export function isWithinWindow(
  window: TimeWindow,
  timestamp: bigint): boolean {
  return window.lower < window.upper && window.lower <= timestamp && timestamp < window.upper
}

/**
 * The proposer's commit window: `[0, proposer.commitmentDeadline)`.
 *
 * Enforced by `Omnibus.commit` via
 * `enforceWithin(0, party.commitmentDeadline, block.timestamp)` on the
 * proposer path.
 *
 * @param proposer - The proposer's terms (the side with the earlier `commitmentDeadline`).
 * @returns The half-open commit window for the proposer.
 * @see Omnibus.commit
 */
export function proposerCommitWindow(
  proposer: Terms): TimeWindow {
  return {
    lower: 0n,
    upper: proposer.commitmentDeadline
  }
}

/**
 * The taker's commit window:
 * `[proposer.commitmentDeadline, taker.commitmentDeadline)`.
 *
 * The taker can only commit AFTER the proposer's commitment deadline has
 * elapsed — enforced by `Omnibus.commit` via
 * `enforceWithin(counterparty.commitmentDeadline, party.commitmentDeadline, block.timestamp)`.
 * A taker commit attempted while the proposer's window is still open
 * reverts with `WindowViolated`.
 *
 * @param taker - The taker's terms.
 * @param proposer - The proposer's terms.
 * @returns The half-open commit window for the taker.
 * @see Omnibus.commit
 */
export function takerCommitWindow(
  taker: Terms,
  proposer: Terms): TimeWindow {
  return {
    lower: proposer.commitmentDeadline,
    upper: taker.commitmentDeadline
  }
}

/**
 * The proposer's claim window:
 * `[taker.commitmentDeadline, proposer.claimDeadline)`.
 *
 * Enforced by `Omnibus.claim` when the claimant role is the proposer:
 * `enforceWithin(counterparty.commitmentDeadline, party.claimDeadline, block.timestamp)`.
 *
 * @param proposer - The proposer's terms.
 * @param taker - The taker's terms.
 * @returns The half-open claim window for the proposer (secret holder).
 * @see Omnibus.claim
 */
export function proposerClaimWindow(
  proposer: Terms,
  taker: Terms): TimeWindow {
  return {
    lower: taker.commitmentDeadline,
    upper: proposer.claimDeadline
  }
}

/**
 * The taker's claim window:
 * `[proposer.claimDeadline, proposer.reclaimRelease)`.
 *
 * Enforced by `Omnibus.claim` when the claimant role is the taker:
 * `enforceWithin(counterparty.claimDeadline, counterparty.reclaimRelease, block.timestamp)`
 * (the counterparty is the proposer on this path). The width of this
 * window, `proposer.reclaimRelease - proposer.claimDeadline`, is the
 * taker's post-reveal reaction buffer in a cross-chain swap.
 *
 * @param proposer - The proposer's terms (the claim is gated on the PROPOSER's schedule).
 * @returns The half-open claim window for the taker.
 * @see Omnibus.claim
 */
export function takerClaimWindow(
  proposer: Terms): TimeWindow {
  return {
    lower: proposer.claimDeadline,
    upper: proposer.reclaimRelease
  }
}

/**
 * The reclaim window for one leg: `[leg.reclaimRelease, +infinity)`.
 *
 * Enforced by `Omnibus.reclaim` via
 * `enforceWithin(party.reclaimRelease, type(uint256).max, block.timestamp)`.
 * Reclaim never closes once open.
 *
 * @param leg - The terms of the leg being reclaimed.
 * @returns The half-open reclaim window (upper bound `MAX_UINT256`).
 * @see Omnibus.reclaim
 */
export function reclaimWindow(
  leg: Terms): TimeWindow {
  return {
    lower: leg.reclaimRelease,
    upper: MAX_UINT256
  }
}

/**
 * Validates that `currentTimestamp` lies inside the commit window for the
 * role `party` plays in the pairing — exactly the check `Omnibus.commit`
 * performs:
 *
 * - `party` is the proposer: `[0, party.commitmentDeadline)`
 * - `party` is the taker: `[counterparty.commitmentDeadline, party.commitmentDeadline)`
 *
 * @param party - The committing side's terms.
 * @param counterparty - The other side's terms.
 * @param currentTimestamp - The chain's current `block.timestamp` (Unix
 *   seconds) — pass an explicit value; this helper never reads a clock.
 * @throws QuipSwapError `WINDOW_VIOLATED` | `INVALID_RANGE` as in
 *   {@link enforceWithin}.
 * @see Omnibus.commit
 * @example
 * ```ts
 * const block = await publicClient.getBlock()
 * validateCommitWindow(myTerms, theirTerms, block.timestamp)
 * ```
 */
export function validateCommitWindow(
  party: Terms,
  counterparty: Terms,
  currentTimestamp: bigint): void {
  if (proposedBy(party, counterparty) === 'party') {
    enforceWithin(0n, party.commitmentDeadline, currentTimestamp)
  } else {
    // taker path: the proposer's (counterparty's) deadline must have elapsed
    enforceWithin(counterparty.commitmentDeadline, party.commitmentDeadline, currentTimestamp)
  }
}

/**
 * Validates that `currentTimestamp` lies inside the claim window for the
 * role `party` plays — exactly the check `Omnibus.claim` performs:
 *
 * - `party` is the proposer: `[counterparty.commitmentDeadline, party.claimDeadline)`
 * - `party` is the taker: `[counterparty.claimDeadline, counterparty.reclaimRelease)`
 *
 * @param party - The claimant role's terms (the side the claimant acts for).
 * @param counterparty - The other side's terms (the leg being claimed).
 * @param currentTimestamp - The chain's current `block.timestamp` (Unix seconds).
 * @throws QuipSwapError `WINDOW_VIOLATED` | `INVALID_RANGE` as in
 *   {@link enforceWithin}.
 * @see Omnibus.claim
 */
export function validateClaimWindow(
  party: Terms,
  counterparty: Terms,
  currentTimestamp: bigint): void {
  if (proposedBy(party, counterparty) === 'party') {
    enforceWithin(counterparty.commitmentDeadline, party.claimDeadline, currentTimestamp)
  } else {
    enforceWithin(counterparty.claimDeadline, counterparty.reclaimRelease, currentTimestamp)
  }
}

/**
 * Validates that `currentTimestamp` has reached the reclaim window of the
 * leg being reclaimed — exactly the check `Omnibus.reclaim` performs:
 * `[party.reclaimRelease, type(uint256).max)`.
 *
 * @param party - The terms of the leg being reclaimed.
 * @param currentTimestamp - The chain's current `block.timestamp` (Unix seconds).
 * @throws QuipSwapError `WINDOW_VIOLATED` when the release has not elapsed.
 * @see Omnibus.reclaim
 */
export function validateReclaimWindow(
  party: Terms,
  currentTimestamp: bigint): void {
  enforceWithin(party.reclaimRelease, MAX_UINT256, currentTimestamp)
}
