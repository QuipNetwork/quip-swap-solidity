/**
 * Commit authorization: signer blobs and the commit digest.
 *
 * `Omnibus.commit` authenticates the PAYLOAD with an identity blob and
 * separately enforces `msg.sender == party.sender`. Every commit carries a
 * {@link CommitAuth}: an identity blob (`signer`) plus either a keyed-route
 * signature or an attested-route wallet binding.
 *
 * FUNDING MODEL: the transaction SENDER funds the committed leg + fee
 * (`msg.sender` pays), and the terms must declare that same sender.
 *
 * The accepted signer shape is an ERC-7913 keyed identity:
 * `verifier(20) ‖ key`; the verifier must be active on the contract.
 * Blobs of 20 bytes or fewer revert `MalformedSigner`.
 *
 * The SDK does NOT sign and does not encode signature envelopes: `signature`
 * is opaque bytes produced by the keyholder's own tooling.
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
  /** The committing side's identity blob: `verifier(20) ‖ key` (see module docs). */
  readonly signer: Hex
  /** Signature over {@link computeCommitDigest}, checked by the declared verifier. */
  readonly signature: Hex
  /** Attested-route witness; keyed route may omit it and defaults to the zero bytes32 value. */
  readonly walletBinding?: Hex32
}

/**
 * The protocol tag bound into the commit-digest domain separator —
 * `keccak256('QUIP:Omnibus:commit')`, mirroring
 * `Omnibus.COMMIT_DIGEST_TAG` exactly (asserted against the contract's
 * `COMMIT_DIGEST_TAG()` in the integration suite).
 */
export const COMMIT_DIGEST_TAG: Hex32 = keccak256(toBytes('QUIP:Omnibus:commit'))

/**
 * Mirrors `Omnibus.DOMAIN_SEPARATOR` (baked at construction on-chain):
 * `keccak256(abi.encode(COMMIT_DIGEST_TAG, chainId, omnibusAddress))`.
 */
export function computeDomainSeparator(chainId: bigint, omnibusAddress: Address): Hex32 {
  return keccak256(
    encodeAbiParameters(
      [{type: 'bytes32'}, {type: 'uint256'}, {type: 'address'}],
      [COMMIT_DIGEST_TAG, chainId, omnibusAddress],
    ),
  )
}

/**
 * Builds a keyed ERC-7913 signer blob: `verifier(20 bytes) ‖ key`.
 *
 * `key` is the verifier-defined key material and `verifier` is a deployed,
 * Omnibus-active ERC-7913 verifier.
 *
 * @param verifier - The ERC-7913 verifier contract address.
 * @param key - The verifier-defined key material (non-empty; the blob must
 *   exceed 20 bytes).
 * @returns The concatenated signer blob.
 * @throws QuipSwapError `MALFORMED_SIGNER` when `verifier` is not an address
 *   or `key` is empty.
 */
export function buildKeyedSigner(verifier: Address, key: Hex): Hex {
  if (!isAddress(verifier)) {
    throw new QuipSwapError({code: 'MALFORMED_SIGNER', message: `verifier must be an address; received ${verifier}`})
  }
  if (!isHex(key, {strict: true}) || size(key) === 0) {
    throw new QuipSwapError({
      code: 'MALFORMED_SIGNER',
      message: 'key must be non-empty hex; the signer blob must exceed 20 bytes',
    })
  }
  return concatHex([verifier, key])
}

/**
 * Validates a signer blob's shape: more than 20 bytes of strict hex — the
 * contract reverts `MalformedSigner` at 20 bytes or fewer. Mirrors, never
 * replaces, the on-chain check.
 *
 * @param signer - The identity blob.
 * @throws QuipSwapError `MALFORMED_SIGNER`.
 */
export function assertSignerBlob(signer: Hex): void {
  if (!isHex(signer, {strict: true}) || size(signer) <= 20) {
    throw new QuipSwapError({
      code: 'MALFORMED_SIGNER',
      message: 'signer must be more than 20 bytes of hex (contract would revert MalformedSigner)',
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
 *   DOMAIN_SEPARATOR, // = keccak256(abi.encode(COMMIT_DIGEST_TAG, block.chainid, address(this)))
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
      [{type: 'bytes32'}, {type: 'bytes32'}, {type: 'bytes32'}, {type: 'bytes32'}, {type: 'bytes32'}],
      [
        computeDomainSeparator(args.party.chainId, args.omnibusAddress),
        args.lock,
        digestTerms(args.party),
        digestTerms(args.counterparty),
        keccak256(args.signer),
      ],
    ),
  )
}
