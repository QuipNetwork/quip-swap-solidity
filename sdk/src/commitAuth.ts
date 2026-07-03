/**
 * Commit authorization: signer blobs and the commit digest.
 *
 * `Omnibus.commit` is PERMISSIONLESS — it authenticates the PAYLOAD, not the
 * caller. Every commit carries a {@link CommitAuth}: an identity blob
 * (`signer`) plus a signature over the commit digest. The signature is a
 * SOFT GUARD: it proves this exact payload (lock + both terms, on this
 * chain, for this contract) was endorsed by the declared identity; it does
 * NOT gate which identity may post a side. Where a client cares WHO posted
 * the counterpart side, it verifies the blob from the `Commitment` event
 * off-chain before revealing the secret / committing the second leg.
 *
 * FUNDING MODEL (state this everywhere): in every route the SENDER of the
 * transaction funds the party's leg + fee (`msg.sender` pays); the identity
 * only AUTHORIZES. "Relayed" means the sender pays the party's leg.
 *
 * Routing by blob shape (see `Omnibus._enforceCommitAuthorized`):
 * - length < 20 bytes  → reverts `MalformedSigner`
 * - length == 20 bytes → an ADDRESS: `msg.sender == address` self-auth (no
 *   signature); no code at address → EOA raw-digest ecrecover; code at
 *   address → ERC-1271 `isValidSignature`
 * - length > 20 bytes  → ERC-7913 keyed: `verifier(20) ‖ key`, verifier must
 *   be owner-allowlisted on the contract
 *
 * The SDK does NOT sign and does not encode signature envelopes: `signature`
 * is opaque bytes produced by the keyholder's own tooling (a SHRINCS WASM
 * signer, a programmatic EOA key signing the RAW 32-byte digest — browser
 * wallets refuse raw hashes and are out of scope — or `0x` for self-auth).
 */
import {concatHex, encodeAbiParameters, isAddress, isHex, keccak256, size, toBytes} from 'viem'
import type {Address, Hex} from 'viem'
import {QuipSwapError} from './errors.js'
import {digestTerms} from './hashing.js'
import type {Hex32, Terms} from './types.js'

/**
 * Auth data for one commit, mirroring the Solidity `struct CommitAuth`
 * field-for-field. Identities attribute, they don't gate.
 */
export interface CommitAuth {
  /** The committing side's identity blob (routes + verifies; see module docs). */
  readonly signer: Hex
  /** Signature over {@link computeCommitDigest}; `'0x'` for self-auth. */
  readonly signature: Hex
}

/**
 * The domain tag bound into every commit digest —
 * `keccak256('QUIP:Omnibus:commit:v1')`, mirroring
 * `Omnibus.COMMIT_DIGEST_TAG` exactly (asserted against the contract's
 * `COMMIT_DIGEST_TAG()` in the integration suite).
 */
export const COMMIT_DIGEST_TAG: Hex32 = keccak256(toBytes('QUIP:Omnibus:commit:v1'))

/**
 * Builds a keyed ERC-7913 signer blob: `verifier(20 bytes) ‖ key`.
 *
 * For the SHRINCS route, `key` is the 32-byte `publicKeyCommitment` and
 * `verifier` is the chain's deployed (and Omnibus-trusted) ShrincsVerifier.
 *
 * @param verifier - The ERC-7913 verifier contract address.
 * @param key - The verifier-defined key material (non-empty; the blob must
 *   exceed 20 bytes to route as keyed).
 * @returns The concatenated signer blob.
 * @throws QuipSwapError `MALFORMED_SIGNER` when `verifier` is not an address
 *   or `key` is empty (a bare 20-byte blob would route as an ADDRESS, not
 *   as a keyed identity).
 */
export function buildKeyedSigner(verifier: Address, key: Hex): Hex {
  if (!isAddress(verifier)) {
    throw new QuipSwapError({code: 'MALFORMED_SIGNER', message: `verifier must be an address; received ${verifier}`})
  }
  if (!isHex(key, {strict: true}) || size(key) === 0) {
    throw new QuipSwapError({
      code: 'MALFORMED_SIGNER',
      message: 'key must be non-empty hex; a bare 20-byte blob routes as an address, not a keyed identity',
    })
  }
  return concatHex([verifier, key])
}

/**
 * The self-auth {@link CommitAuth} for an account that will BE `msg.sender`
 * of the commit (an EOA sending directly, or a QuipWallet executing the
 * calldata): the identity is the bare address and no signature is needed.
 *
 * @param account - The address that will send (or execute) the commit.
 * @returns `{signer: account, signature: '0x'}`.
 */
export function selfAuth(account: Address): CommitAuth {
  if (!isAddress(account)) {
    throw new QuipSwapError({code: 'MALFORMED_SIGNER', message: `account must be an address; received ${account}`})
  }
  return {signer: account, signature: '0x'}
}

/**
 * Validates a signer blob's shape: at least 20 bytes of strict hex — the
 * contract reverts `MalformedSigner` below that. Mirrors, never replaces,
 * the on-chain check.
 *
 * @param signer - The identity blob.
 * @throws QuipSwapError `MALFORMED_SIGNER`.
 */
export function assertSignerBlob(signer: Hex): void {
  if (!isHex(signer, {strict: true}) || size(signer) < 20) {
    throw new QuipSwapError({
      code: 'MALFORMED_SIGNER',
      message: 'signer must be at least 20 bytes of hex (contract would revert MalformedSigner)',
    })
  }
}

/** Argument object for {@link computeCommitDigest}. */
export interface ComputeCommitDigestArgs {
  /** The hashlock identifying the swap instance. */
  readonly lock: Hex32
  /** The COMMITTING side's terms (its `chainId` is the digest's replay scope). */
  readonly party: Terms
  /** The other side's terms. */
  readonly counterparty: Terms
  /** The committing side's full identity blob (hashed into the digest). */
  readonly signer: Hex
  /** The Omnibus deployed on the COMMITTING side's chain. */
  readonly omnibusAddress: Address
}

/**
 * Computes the 32-byte digest a committer's identity must sign — an exact
 * mirror of `Omnibus._commitDigest` (raw tagged keccak, `abi.encode`, NOT
 * packed; no EIP-712):
 *
 * ```solidity
 * keccak256(abi.encode(
 *   COMMIT_DIGEST_TAG, block.chainid, address(this),
 *   lock, digestTerms(party), digestTerms(counterparty), keccak256(signer)))
 * ```
 *
 * `chainId` is the COMMITTING side's chain (`party.chainId` — commit enforces
 * `party.chainId == block.chainid`) and `omnibusAddress` is the Omnibus on
 * THAT chain: each side of a cross-chain swap signs its own chain's digest.
 * The digest is never transmitted — the contract recomputes it from calldata
 * and equality is proven implicitly by signature validity.
 *
 * Parity with the contract's `commitDigest` view is asserted by the
 * integration suite (this is the #1 drift risk of the whole client).
 *
 * @param args - See {@link ComputeCommitDigestArgs}.
 * @returns The digest to hand to the keyholder's signing tooling.
 */
export function computeCommitDigest(args: ComputeCommitDigestArgs): Hex32 {
  assertSignerBlob(args.signer)
  return keccak256(
    encodeAbiParameters(
      [
        {type: 'bytes32'},
        {type: 'uint256'},
        {type: 'address'},
        {type: 'bytes32'},
        {type: 'bytes32'},
        {type: 'bytes32'},
        {type: 'bytes32'},
      ],
      [
        COMMIT_DIGEST_TAG,
        args.party.chainId,
        args.omnibusAddress,
        args.lock,
        digestTerms(args.party),
        digestTerms(args.counterparty),
        keccak256(args.signer),
      ],
    ),
  )
}
