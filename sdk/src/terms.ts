/**
 * Terms construction, structural validation, and pairing validation.
 *
 * Transcribes `TermsLib.validateTerms`, `TermsLib.validateTermPairing`, and
 * `TermsLib.proposedByParty`.
 */
import {isHex} from 'viem'
import type {Address} from 'viem'
import {validateAsset} from './assets.js'
import {AssetType} from './types.js'
import {U64_MAX, isSvmChainId} from './chains.js'
import {QuipSwapError} from './errors.js'
import type {Asset, Hex32, Terms} from './types.js'
import {bytes32ToEvm, toUniversalAddress} from './universalAddress.js'

/** Input shape for {@link createTerms}; identical to {@link Terms} except
 * recipients accept either form of address and are normalized. */
export interface CreateTermsArgs {
  /** Chain id where this side's assets live; must be `> 0n`. */
  readonly chainId: bigint
  /**
   * Receives this side's own assets on reclaim; non-zero. Lives on THIS
   * leg's chain. A 20-byte EVM address (widened automatically) or a 32-byte
   * universal identifier.
   */
  readonly reclaimRecipient: Address | Hex32
  /**
   * Receives the COUNTERPARTY's assets on claim; non-zero. Lives on the
   * COUNTERPARTY's chain — pass a Solana owner-wallet pubkey (32-byte hex)
   * when the counterparty leg is on Solana.
   */
  readonly recipient: Address | Hex32
  /** Unix seconds; commitment forbidden at/after this instant; non-zero. */
  readonly commitmentDeadline: bigint
  /** Unix seconds; strictly after `commitmentDeadline`. */
  readonly claimDeadline: bigint
  /** Unix seconds; strictly after `claimDeadline`. */
  readonly reclaimRelease: bigint
  /**
   * Waives the commit/claim window LOWER bounds when the counterparty sets
   * it too; defaults to `false`. Both sides must match
   * (contract: OptimismMismatch).
   */
  readonly optimistic?: boolean
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
    reclaimRecipient: toUniversalAddress(args.reclaimRecipient),
    recipient: toUniversalAddress(args.recipient),
    commitmentDeadline: args.commitmentDeadline,
    claimDeadline: args.claimDeadline,
    reclaimRelease: args.reclaimRelease,
    optimistic: args.optimistic ?? false,
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
 * if (reclaimRecipient == 0 || recipient == 0) revert ZeroRecipient();
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
 * @throws QuipSwapError `EMPTY_ASSETS` | `ZERO_RECIPIENT` |
 *   `ZERO_DEADLINE` | `DISORDERED_DEADLINES` | `ZERO_CHAIN_ID`, plus every
 *   asset-level code from {@link validateAsset}.
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
  if (!isRecipientValue(terms.reclaimRecipient) || !isRecipientValue(terms.recipient)) {
    throw new QuipSwapError({
      code: 'ZERO_RECIPIENT',
      message:
        'Both recipient and reclaimRecipient must be non-zero 32-byte universal addresses (contract: ZeroRecipient)',
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
  if (isSvmChainId(terms.chainId)) validateSvmLeg(terms)
}

/** True when the value is well-formed 32-byte hex and non-zero. */
function isRecipientValue(value: Hex32): boolean {
  return isHex(value, {strict: true}) && value.length === 66 && BigInt(value) !== 0n
}

/**
 * SDK-only conventions for legs on a known SVM chain (see `chains.ts`);
 * NOT contract-enforceable — the EVM contract only hashes a foreign leg.
 * A violating leg is HTLC-safe (it can never commit on Solana, so the other
 * side reclaims) but parks the counterparty's funds until reclaimRelease,
 * so the SDK rejects it before any terms are signed.
 */
function validateSvmLeg(terms: Terms): void {
  for (const asset of terms.assets) {
    if (asset.assetType === AssetType.ERC1155) {
      throw new QuipSwapError({
        code: 'UNSUPPORTED_SVM_ASSET',
        message:
          'ERC-1155-semantics assets are unsupported on SVM legs: Solana has no (contract, id) token dimension',
        details: {chainId: terms.chainId, asset},
      })
    }
    if (asset.assetType === AssetType.ERC721 && asset.id !== 0n) {
      throw new QuipSwapError({
        code: 'UNSUPPORTED_SVM_ASSET',
        message:
          'ERC-721-semantics assets on SVM legs must have id 0: the mint pubkey (target) IS the NFT identity',
        details: {chainId: terms.chainId, asset},
      })
    }
    if (asset.amount > U64_MAX) {
      throw new QuipSwapError({
        code: 'AMOUNT_EXCEEDS_U64',
        message:
          `Asset amount ${asset.amount} exceeds u64 max (${U64_MAX}); SPL token amounts are u64, so this ` +
          'leg could never be committed on Solana',
        details: {chainId: terms.chainId, asset},
      })
    }
  }
}

/**
 * Preflights the EVM-addressing constraints `Omnibus.commit` will enforce
 * for a commit of `party` (the leg escrowed on the connected EVM chain)
 * against `counterparty`.
 *
 * Mirrors the contract exactly, plus one SDK-only early catch:
 * - `party.assets[].target` and `party.reclaimRecipient` must narrow
 *   (contract: `validateLocalLeg`).
 * - `counterparty.recipient` must narrow — whoever claims the party's
 *   escrow is paid on THIS chain at that field.
 * - `party.recipient` must narrow ONLY when the pairing is same-chain
 *   (`counterparty.chainId === party.chainId`). The contract defers this to
 *   the counterparty's own commit; checking it here stops the client from
 *   locking funds into a same-chain pairing that can never settle. On a
 *   cross-chain pairing `party.recipient` legitimately carries a foreign
 *   pubkey and is NOT checked.
 *
 * @param party - The leg being committed on the connected (EVM) chain.
 * @param counterparty - The other leg (may be on a non-EVM chain).
 * @throws QuipSwapError `NOT_EVM_ADDRESS` naming the offending field
 *   (contract: NotEvmAddress).
 * @see TermsLib.validateLocalLeg, Omnibus.commit
 */
export function assertEvmLocalLeg(party: Terms, counterparty: Terms): void {
  narrowField(party.reclaimRecipient, 'party.reclaimRecipient')
  for (const [i, asset] of party.assets.entries()) {
    if (asset.assetType !== AssetType.Native) narrowField(asset.target, `party.assets[${i}].target`)
  }
  narrowField(counterparty.recipient, 'counterparty.recipient')
  if (counterparty.chainId === party.chainId) narrowField(party.recipient, 'party.recipient')
}

/** Narrows one field, rewrapping the error with the field name. */
function narrowField(value: Hex32, field: string): void {
  try {
    bytes32ToEvm(value)
  } catch (error) {
    if (error instanceof QuipSwapError && error.code === 'NOT_EVM_ADDRESS') {
      throw new QuipSwapError({
        code: 'NOT_EVM_ADDRESS',
        message:
          `${field} (${value}) must be an EVM address (low 20 bytes) — it is dereferenced on this chain ` +
          '(contract: NotEvmAddress)',
        details: {field, value},
        cause: error,
      })
    }
    throw error
  }
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
 * Additionally requires the two sides' `optimistic` flags to be EQUAL —
 * optimistic mode (waived commit/claim lower bounds) is a bilateral opt-in.
 *
 * @param a - One side's terms.
 * @param b - The other side's terms.
 * @throws QuipSwapError `DISORDERED_DEADLINES` when neither interleaving
 *   holds (contract: DisordedDeadlines); `OPTIMISM_MISMATCH` when exactly
 *   one side sets `optimistic` (contract: OptimismMismatch).
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

  // optimistic mode is a bilateral opt-in: both flags must be equal (checked
  // AFTER the interleaving so DisordedDeadlines stays the primary structural error)
  if (a.optimistic !== b.optimistic) {
    throw new QuipSwapError({
      code: 'OPTIMISM_MISMATCH',
      message: "The two sides' optimistic flags must be equal (contract: OptimismMismatch)",
      details: {a: a.optimistic, b: b.optimistic},
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
