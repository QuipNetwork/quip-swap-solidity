/**
 * Solidity-exact hashing and ABI encoding.
 *
 * These functions are byte-for-byte transcriptions of
 * `TermsLib.digestTerms`, `TermsLib.digestTermsCanonically`, and
 * `Omnibus._generateLock`. ANY deviation here breaks hash agreement with
 * the contract — and across chains, since both legs of a cross-chain swap
 * derive the same canonical digest independently. Correctness is proven by
 * differential tests against the Solidity harnesses (the harness is the
 * oracle), not assumed.
 */
import {concat, encodeAbiParameters, isHex, keccak256} from 'viem'
import {QuipSdkError} from './errors.js'
import type {Hex32, Terms} from './types.js'

/**
 * The ABI parameter description of the `Asset[]` array — the SINGLE source
 * of truth for the Asset tuple shape in the SDK. `assetType` is a Solidity
 * enum, encoded as `uint8` in the ABI.
 *
 * @see TermsLib (struct Asset)
 */
export const assetArrayAbiParameter = {
  name: 'assets',
  type: 'tuple[]',
  components: [
    {name: 'assetType', type: 'uint8'},
    {name: 'target', type: 'address'},
    {name: 'id', type: 'uint256'},
    {name: 'amount', type: 'uint256'},
  ],
} as const

/**
 * The ABI parameter description of the full `Terms` tuple — the SINGLE
 * source of truth for the Terms shape. Used to decode the `Commitment`
 * event's `party` field back into a typed {@link Terms}.
 *
 * Note: {@link digestTerms} does NOT use this tuple — the contract hashes
 * `abi.encode(field1, ..., field7)` (seven separate top-level values), not
 * `abi.encode(struct)`; for a single dynamic struct argument those two
 * encodings differ by a leading offset word.
 *
 * @see TermsLib (struct Terms), IOmnibus.Commitment
 */
export const termsAbiParameter = {
  name: 'terms',
  type: 'tuple',
  components: [
    {name: 'chainId', type: 'uint256'},
    {name: 'reclaimRecipient', type: 'address'},
    {name: 'recipient', type: 'address'},
    {name: 'commitmentDeadline', type: 'uint256'},
    {name: 'claimDeadline', type: 'uint256'},
    {name: 'reclaimRelease', type: 'uint256'},
    assetArrayAbiParameter,
  ],
} as const

/**
 * The seven top-level ABI parameters hashed by `TermsLib.digestTerms`, in
 * the exact order the contract encodes them.
 */
const termsDigestAbiParameters = [
  {name: 'chainId', type: 'uint256'},
  {name: 'reclaimRecipient', type: 'address'},
  {name: 'recipient', type: 'address'},
  {name: 'commitmentDeadline', type: 'uint256'},
  {name: 'claimDeadline', type: 'uint256'},
  {name: 'reclaimRelease', type: 'uint256'},
  assetArrayAbiParameter,
] as const

/**
 * Computes the digest of a single side's terms.
 *
 * Exact transcription of `TermsLib.digestTerms`:
 *
 * ```solidity
 * digest = EfficientHashLib.hash(            // keccak256(bytes)
 *   abi.encode(
 *     terms.chainId, terms.reclaimRecipient, terms.recipient,
 *     terms.commitmentDeadline, terms.claimDeadline, terms.reclaimRelease,
 *     terms.assets
 *   )
 * );
 * ```
 *
 * Standard (head/tail) ABI encoding of SEVEN top-level values — not packed
 * encoding, and not the encoding of a single `Terms` struct. The asset
 * order matters: reordering assets changes the digest.
 *
 * @param terms - The side's terms.
 * @returns The 32-byte digest used for `posted` tracking and canonical ordering.
 * @see TermsLib.digestTerms
 * @example
 * ```ts
 * const digest = digestTerms(aliceTerms)
 * const isPosted = await client.posted(lock, digest)
 * ```
 */
export function digestTerms(terms: Terms): Hex32 {
  return keccak256(
    encodeAbiParameters(termsDigestAbiParameters, [
      terms.chainId,
      terms.reclaimRecipient,
      terms.recipient,
      terms.commitmentDeadline,
      terms.claimDeadline,
      terms.reclaimRelease,
      // readonly Asset[] is structurally compatible with the tuple components
      terms.assets.map(a => ({assetType: a.assetType, target: a.target, id: a.id, amount: a.amount})),
    ]),
  )
}

/**
 * Computes the canonical digest of a terms pair, identical regardless of
 * which side is passed first.
 *
 * Exact transcription of `TermsLib.digestTermsCanonically`:
 * 1. Digest each side independently with {@link digestTerms}.
 * 2. Compare the two digests as unsigned 256-bit integers — NOT as strings
 *    (string comparison is locale/casing-sensitive and does not match
 *    Solidity's `uint256(a) < uint256(b)`).
 * 3. Concatenate the raw 32-byte values, smaller digest first.
 * 4. keccak256 the 64-byte concatenation (matching
 *    `EfficientHashLib.hash(bytes32, bytes32)`).
 *
 * This is the value stored in `Omnibus.termsHash[lock]`; both chains of a
 * cross-chain swap must derive it identically.
 *
 * @param party - One side's terms (order does not matter).
 * @param counterparty - The other side's terms.
 * @returns The canonical 32-byte digest of the pair.
 * @see TermsLib.digestTermsCanonically
 * @example
 * ```ts
 * digestTermsCanonically(a, b) === digestTermsCanonically(b, a) // always true
 * ```
 */
export function digestTermsCanonically(party: Terms, counterparty: Terms): Hex32 {
  const partyDigest = digestTerms(party)
  const counterpartyDigest = digestTerms(counterparty)
  // canonical ordering: numerically smaller digest first (unsigned-bigint compare)
  return BigInt(partyDigest) < BigInt(counterpartyDigest)
    ? keccak256(concat([partyDigest, counterpartyDigest]))
    : keccak256(concat([counterpartyDigest, partyDigest]))
}

/**
 * Derives the hashlock from a secret.
 *
 * Exact transcription of `Omnibus._generateLock`: keccak256 over the raw
 * 32-byte secret (matching `EfficientHashLib.hash(bytes32)` — no length
 * prefix, no ABI encoding).
 *
 * @param secret - A 32-byte hex preimage (`0x` + 64 hex chars). Validated
 *   before hashing — externally supplied secrets of the wrong length would
 *   otherwise silently produce a lock that can never be claimed.
 * @returns The 32-byte lock, `keccak256(secret)`.
 * @throws QuipSdkError `INVALID_HEX32` if `secret` is not exactly 32 bytes
 *   of valid hex.
 * @see Omnibus._generateLock
 * @example
 * ```ts
 * const lock = generateLock('0x' + '11'.repeat(32) as Hex32)
 * ```
 */
export function generateLock(secret: Hex32): Hex32 {
  assertHex32(secret, 'secret')
  return keccak256(secret)
}

/**
 * Asserts a value is exactly 32 bytes of valid hex (`0x` + 64 hex chars).
 *
 * @param value - The value to check.
 * @param label - Name used in the error message (e.g. `"secret"`, `"lock"`).
 * @throws QuipSdkError `INVALID_HEX32` when malformed or the wrong length.
 */
export function assertHex32(value: string, label: string): asserts value is Hex32 {
  if (!isHex(value, {strict: true}) || value.length !== 66) {
    // do not echo the value itself: it may be a secret and must never be logged
    throw new QuipSdkError({
      code: 'INVALID_HEX32',
      message: `${label} must be a 0x-prefixed 32-byte hex string (66 chars total); received ${
        typeof value === 'string' ? `${value.length} chars` : typeof value
      }`,
    })
  }
}
