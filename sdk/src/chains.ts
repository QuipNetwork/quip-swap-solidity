/**
 * Chain-identity constants and SVM-leg conventions.
 *
 * Solana has no native chain id, so SVM chains are identified by PINNED
 * `uint256` constants derived as `keccak256(<name>)` — collision-free with
 * every EVM chain id (real chain ids are small integers; these have high
 * bits set). These values are part of the terms digest: both sides of a
 * swap and every implementation (Solidity, TS, the future Solana program)
 * must agree on them byte-for-byte. NEVER change them once any terms have
 * been signed against them.
 *
 * ## SVM asset-type conventions (part of the digest agreement)
 *
 * | AssetType | SVM meaning            | target       | id | amount      |
 * |-----------|------------------------|--------------|----|-------------|
 * | Native    | SOL                    | zero         | 0  | lamports    |
 * | ERC20     | SPL fungible token     | mint pubkey  | 0  | base units  |
 * | ERC721    | vanilla SPL/Metaplex NFT (the mint IS the NFT) | mint pubkey | 0 | 1 |
 * | ERC1155   | UNSUPPORTED — Solana has no (contract, id) dimension |
 *
 * Excluded on SVM: programmable NFTs (rulesets can block escrow), compressed
 * NFTs (not mint-addressed), Token-2022 with transfer hooks (case-by-case).
 *
 * ## SVM recipient semantics (part of the digest agreement)
 *
 * An SVM `recipient` / `reclaimRecipient` is the OWNER WALLET pubkey, not a
 * token-account address. One recipient covers an array of assets (plus
 * possibly SOL), which a per-mint token account cannot; the Solana program
 * derives the associated token account `ATA(owner, mint)` per asset at
 * payout and creates it idempotently (claimer pays rent).
 *
 * ## Amounts
 *
 * SPL token amounts are `u64`. A leg whose amount exceeds {@link U64_MAX}
 * can never be committed on Solana — HTLC-safe (the other side reclaims)
 * but a funds-parked-until-reclaim trap, so the SDK rejects it up front.
 */
import {keccak256, stringToHex} from 'viem'

/** Pinned chain id for Solana mainnet-beta: `uint256(keccak256('solana:mainnet'))`. */
export const SOLANA_MAINNET_CHAIN_ID: bigint = BigInt(keccak256(stringToHex('solana:mainnet')))

/** Pinned chain id for Solana devnet: `uint256(keccak256('solana:devnet'))`. */
export const SOLANA_DEVNET_CHAIN_ID: bigint = BigInt(keccak256(stringToHex('solana:devnet')))

/** Every chain id the SDK treats as an SVM chain. */
export const SVM_CHAIN_IDS: readonly bigint[] = Object.freeze([SOLANA_MAINNET_CHAIN_ID, SOLANA_DEVNET_CHAIN_ID])

/** The largest amount representable on an SVM leg (SPL amounts are u64). */
export const U64_MAX: bigint = 2n ** 64n - 1n

/**
 * True when `chainId` names a known SVM chain.
 *
 * Drives the SVM-specific leg validation in `validateTerms` (u64 amounts,
 * supported asset types). Unknown chain ids get no SVM treatment — an EVM
 * chain id is any value not in {@link SVM_CHAIN_IDS}.
 */
export function isSvmChainId(chainId: bigint): boolean {
  return SVM_CHAIN_IDS.includes(chainId)
}
