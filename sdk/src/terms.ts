/**
 * Terms construction, structural validation, and pairing validation.
 *
 * Transcribes `TermsLib.validateTerms`, `TermsLib.validateTermPairing`, and
 * `TermsLib.proposedByParty`.
 */
import {isAddress, zeroAddress} from 'viem'
import type {Address} from 'viem'
import {validateAsset} from './assets.js'
import {QuipSwapError} from './errors.js'
import type {Asset, Terms} from './types.js'

/**
 * Maximum assets permitted in a single side's terms — mirrors
 * `TermsLib.MAX_ASSETS_PER_SIDE`. Bounds the per-side `assets` array so that
 * settling both legs together (same-chain `claim`) always fits the block gas
 * limit; without it a padded leg could commit yet make every claim/reclaim
 * exceed the limit forever (a freeze, and cross-chain a theft).
 */
export const MAX_ASSETS_PER_SIDE = 20

/** Input shape for {@link createTerms}; identical to {@link Terms}. */
export interface CreateTermsArgs {
  /** Chain id where this side's assets live; must be `> 0n`. */
  readonly chainId: bigint
  /** Receives this side's own assets on reclaim; non-zero. */
  readonly reclaimRecipient: Address
  /** Receives the COUNTERPARTY's assets on claim; non-zero. */
  readonly recipient: Address
  /** Unix seconds; commitment forbidden at/after this instant; non-zero. */
  readonly commitmentDeadline: bigint
  /** Unix seconds; strictly after `commitmentDeadline`. */
  readonly claimDeadline: bigint
  /** Unix seconds; strictly after `claimDeadline`. */
  readonly reclaimRelease: bigint
  /** Non-empty list of structurally valid assets. */
  readonly assets: readonly Asset[]
}

/**
 * Builds and validates a {@link Terms} object.
 *
 * The returned object is frozen (including a defensive copy of the asset
 * array) so later mutation of caller-supplied inputs cannot desynchronize a
 * digest already shared with a counterparty.
 *
 * @param args - The seven Terms fields; see {@link CreateTermsArgs} for
 *   units and constraints.
 * @returns A frozen, structurally valid `Terms`.
 * @throws QuipSwapError - every code listed on {@link validateTerms}.
 * @see TermsLib.validateTerms
 * @example
 * ```ts
 * const terms = createTerms({
 *   chainId: 8453n,
 *   reclaimRecipient: wallet,
 *   recipient: wallet,
 *   commitmentDeadline: now + 600n,
 *   claimDeadline: now + 1800n,
 *   reclaimRelease: now + 3600n,
 *   assets: [nativeAsset(10n ** 18n)],
 * })
 * ```
 */
export function createTerms(args: CreateTermsArgs): Terms {
  // defensive copy: never mutate or alias the caller's array
  const terms: Terms = Object.freeze({
    chainId: args.chainId,
    reclaimRecipient: args.reclaimRecipient,
    recipient: args.recipient,
    commitmentDeadline: args.commitmentDeadline,
    claimDeadline: args.claimDeadline,
    reclaimRelease: args.reclaimRelease,
    assets: Object.freeze([...args.assets]),
  })
  validateTerms(terms)
  return terms
}

/**
 * Structurally validates one side's terms.
 *
 * Exact transcription of `TermsLib.validateTerms`:
 *
 * ```solidity
 * if (terms.assets.length == 0) revert EmptyAssets();
 * if (terms.assets.length > MAX_ASSETS_PER_SIDE) revert TooManyAssets();
 * if (reclaimRecipient == 0 || recipient == 0) revert ZeroAddressRecipient();
 * if (terms.commitmentDeadline == 0) revert ZeroDeadline();
 * if (!(commitmentDeadline < claimDeadline && claimDeadline < reclaimRelease))
 *   revert DisordedDeadlines();
 * enforceNonZeroChainId(terms); validateAssets(terms);
 * ```
 *
 * Deliberately does NOT check that deadlines are in the future: freshness
 * is enforced per-action by the half-open windows
 * (see {@link validateCommitWindow}). The taker legitimately commits AFTER
 * the proposer's commitment deadline has elapsed — `Omnibus.commit`
 * validates BOTH sides' terms, so a freshness check here would wrongly
 * reject the proposer's already-elapsed deadline during the taker's commit.
 *
 * @param terms - The terms to validate (e.g. parsed from JSON or an API).
 * @throws QuipSwapError `EMPTY_ASSETS` | `TOO_MANY_ASSETS` |
 *   `ZERO_ADDRESS_RECIPIENT` | `ZERO_DEADLINE` | `DISORDERED_DEADLINES` |
 *   `ZERO_CHAIN_ID`, plus every asset-level code from {@link validateAsset}.
 * @see TermsLib.validateTerms
 * @example
 * ```ts
 * validateTerms(termsFromCounterparty) // throws before any tx is built
 * ```
 */
export function validateTerms(terms: Terms): void {
  if (terms.assets.length === 0) {
    throw new QuipSwapError({
      code: 'EMPTY_ASSETS',
      message: 'Terms must contain at least one asset (contract: EmptyAssets)',
    })
  }
  if (terms.assets.length > MAX_ASSETS_PER_SIDE) {
    throw new QuipSwapError({
      code: 'TOO_MANY_ASSETS',
      message:
        `Terms may carry at most ${MAX_ASSETS_PER_SIDE} assets per side; got ${terms.assets.length} ` +
        '(contract: TooManyAssets)',
      details: {count: terms.assets.length, max: MAX_ASSETS_PER_SIDE},
    })
  }
  if (!isRecipientAddress(terms.reclaimRecipient) || !isRecipientAddress(terms.recipient)) {
    throw new QuipSwapError({
      code: 'ZERO_ADDRESS_RECIPIENT',
      message:
        'Both recipient and reclaimRecipient must be valid non-zero addresses (contract: ZeroAddressRecipient)',
      details: {recipient: terms.recipient, reclaimRecipient: terms.reclaimRecipient},
    })
  }
  if (terms.commitmentDeadline === 0n) {
    throw new QuipSwapError({
      code: 'ZERO_DEADLINE',
      message: 'commitmentDeadline must be non-zero (contract: ZeroDeadline)',
    })
  }
  // lifecycle deadlines must be STRICTLY increasing: commitment < claim < reclaim
  if (!(terms.commitmentDeadline < terms.claimDeadline && terms.claimDeadline < terms.reclaimRelease)) {
    throw new QuipSwapError({
      code: 'DISORDERED_DEADLINES',
      message:
        'Lifecycle timestamps must satisfy commitmentDeadline < claimDeadline < reclaimRelease, strictly ' +
        '(contract: DisordedDeadlines)',
      details: {
        commitmentDeadline: terms.commitmentDeadline,
        claimDeadline: terms.claimDeadline,
        reclaimRelease: terms.reclaimRelease,
      },
    })
  }
  if (terms.chainId <= 0n) {
    throw new QuipSwapError({
      code: 'ZERO_CHAIN_ID',
      message: 'chainId must be greater than zero (contract: ZeroChainId)',
      details: {chainId: terms.chainId},
    })
  }
  for (const asset of terms.assets) validateAsset(asset)
}

/** True when the value is a well-formed, non-zero address. */
function isRecipientAddress(value: Address): boolean {
  return isAddress(value, {strict: false}) && value.toLowerCase() !== zeroAddress
}

/**
 * Validates that two sides' lifecycle timestamps strictly interleave.
 *
 * Exact transcription of `TermsLib.validateTermPairing`. Exactly one of
 * the two chains must hold (every comparison strict — equal timestamps
 * anywhere are rejected):
 *
 * ```text
 * A proposes: A.commitmentDeadline < B.commitmentDeadline < A.claimDeadline
 *               < B.claimDeadline < A.reclaimRelease < B.reclaimRelease
 * B proposes: the same chain with A and B swapped
 * ```
 *
 * The proposer is the side with the smaller `commitmentDeadline` and
 * commits first. The interleaving is what bounds each side's risk — in a
 * cross-chain swap it guarantees the taker a reaction buffer after the
 * secret is revealed (see {@link validateCrossChainSchedule}).
 *
 * @param a - One side's terms.
 * @param b - The other side's terms.
 * @throws QuipSwapError `DISORDERED_DEADLINES` when neither interleaving
 *   holds (contract: DisordedDeadlines).
 * @see TermsLib.validateTermPairing
 * @example
 * ```ts
 * validateTermPairing(aliceTerms, bobTerms) // throws if the schedule is invalid
 * ```
 */
export function validateTermPairing(a: Terms, b: Terms): void {
  const aProposes =
    a.commitmentDeadline < b.commitmentDeadline &&
    b.commitmentDeadline < a.claimDeadline &&
    a.claimDeadline < b.claimDeadline &&
    b.claimDeadline < a.reclaimRelease &&
    a.reclaimRelease < b.reclaimRelease

  const bProposes =
    b.commitmentDeadline < a.commitmentDeadline &&
    a.commitmentDeadline < b.claimDeadline &&
    b.claimDeadline < a.claimDeadline &&
    a.claimDeadline < b.reclaimRelease &&
    b.reclaimRelease < a.reclaimRelease

  if (!(aProposes || bProposes)) {
    throw new QuipSwapError({
      code: 'DISORDERED_DEADLINES',
      message:
        "The two sides' lifecycle timestamps must strictly interleave " +
        '(proposer.commit < taker.commit < proposer.claim < taker.claim < proposer.reclaim < taker.reclaim; ' +
        'contract: DisordedDeadlines)',
      details: {a: lifecycleOf(a), b: lifecycleOf(b)},
    })
  }
}

/** Extracts just the three lifecycle timestamps for error reporting. */
function lifecycleOf(terms: Terms): Record<string, bigint> {
  return {
    commitmentDeadline: terms.commitmentDeadline,
    claimDeadline: terms.claimDeadline,
    reclaimRelease: terms.reclaimRelease,
  }
}

/**
 * Identifies which side of a pairing proposed.
 *
 * Transcribes `TermsLib.proposedByParty`: the proposer is the side with
 * the smaller `commitmentDeadline` (it commits first). Only meaningful
 * after {@link validateTermPairing} has passed, which guarantees the
 * commitment deadlines are strictly ordered and never equal.
 *
 * @param party - The first side's terms.
 * @param counterparty - The second side's terms.
 * @returns `'party'` if `party` proposed, `'counterparty'` otherwise.
 * @see TermsLib.proposedByParty
 * @example
 * ```ts
 * if (proposedBy(mine, theirs) === 'party') {
 *   // I commit first, in [0, mine.commitmentDeadline)
 * }
 * ```
 */
export function proposedBy(party: Terms, counterparty: Terms): 'party' | 'counterparty' {
  return party.commitmentDeadline < counterparty.commitmentDeadline ? 'party' : 'counterparty'
}
