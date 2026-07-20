/**
 * Asset builders and structural validation.
 *
 * The validation rules transcribe `TermsLib.validateAsset` exactly; the one
 * deliberate divergence (ERC-721 amount canonicalization) is marked with
 * `SDK-STRICTER-THAN-CONTRACT` below.
 *
 * Targets are universal bytes32 identifiers: builders accept either a
 * 20-byte EVM token address (widened to the low-20-byte form) or a full
 * 32-byte identifier such as an SPL mint pubkey — see `universalAddress.ts`.
 * Like the contract's `validateAsset`, validation here is chain-agnostic: a
 * foreign (high-bit) target is structurally valid, because whether it must
 * narrow to an EVM address depends on which chain escrows the leg (see
 * `assertEvmLocalLeg`).
 */
import type {Address} from 'viem'
import {QuipSwapError} from './errors.js'
import {AssetType} from './types.js'
import type {Asset, Hex32, Terms} from './types.js'
import {ZERO_BYTES32, toUniversalAddress} from './universalAddress.js'

/**
 * Builds a native-currency asset (ETH, SOL, or the chain's equivalent).
 *
 * Canonical fields enforced — mirrors the contract's native-asset rule:
 * `target` must be zero and `id` must be `0`, otherwise the contract
 * reverts with `InvalidNativeAsset`.
 *
 * @param amount - Amount of native currency in base units (wei/lamports);
 *   must be `> 0n`.
 * @returns A canonical, frozen `Asset` with `assetType: Native`.
 * @throws QuipSwapError `ZERO_AMOUNT` if `amount` is zero or negative.
 * @see TermsLib.validateAsset
 * @example
 * ```ts
 * const oneEth = nativeAsset(10n ** 18n)
 * ```
 */
export function nativeAsset(amount: bigint): Asset {
  if (amount <= 0n) {
    throw new QuipSwapError({
      code: 'ZERO_AMOUNT',
      message: 'Native asset amount must be greater than zero (contract: ZeroAmount)',
      details: {amount},
    })
  }
  return Object.freeze({assetType: AssetType.Native, target: ZERO_BYTES32, id: 0n, amount})
}

/**
 * Builds an ERC-20-semantics asset (an ERC-20 token on EVM legs, an SPL
 * fungible mint on SVM legs).
 *
 * The id is fixed at `0n`: the contract REJECTS a non-zero id for ERC-20
 * with `InvalidERC20Asset` (the id field is meaningless for fungible
 * tokens but is still hashed into the terms digest).
 *
 * @param target - The token identifier: a 20-byte EVM contract address or a
 *   32-byte identifier (e.g. an SPL mint pubkey as hex); must be non-zero.
 * @param amount - Token amount in the token's base units; must be `> 0n`.
 * @returns A canonical, frozen `Asset` with `assetType: ERC20` and `id: 0n`.
 * @throws QuipSwapError `INVALID_ERC20_ASSET` if `target` is zero;
 *   `INVALID_UNIVERSAL_ADDRESS` if malformed; `ZERO_AMOUNT` if `amount <= 0n`.
 * @see TermsLib.validateAsset
 * @example
 * ```ts
 * const usdc = erc20Asset('0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', 1_000_000n)
 * ```
 */
export function erc20Asset(target: Address | Hex32, amount: bigint): Asset {
  const universal = normalizeTokenTarget(target, 'INVALID_ERC20_ASSET', 'ERC-20')
  if (amount <= 0n) {
    throw new QuipSwapError({
      code: 'ZERO_AMOUNT',
      message: 'ERC-20 asset amount must be greater than zero (contract: ZeroAmount)',
      details: {target, amount},
    })
  }
  return Object.freeze({assetType: AssetType.ERC20, target: universal, id: 0n, amount})
}

/**
 * Builds an ERC-721-semantics asset for one specific NFT.
 *
 * Token id `0n` is explicitly VALID — do not pre-filter it out; the
 * contract permits id 0 for ERC-721 (see the comment in
 * `TermsLib.validateAsset`). On SVM legs the mint IS the NFT's identity, so
 * the id is always `0n` there (see `chains.ts`).
 *
 * SDK-STRICTER-THAN-CONTRACT: the amount is canonicalized to `1n`. The
 * contract only enforces `amount != 0`, but the amount is hashed into the
 * terms digest while the transfer always moves exactly the one NFT
 * identified by `tokenId` — so two different amounts would yield two
 * different digests describing the same effective transfer. Canonicalizing
 * to `1n` (matching the repository's `AssetHelper.makeERC721`) prevents
 * that ambiguity. Validation of externally supplied assets
 * ({@link validateAsset}) follows the contract and accepts any non-zero
 * amount.
 *
 * @param target - The token identifier: a 20-byte EVM contract address or a
 *   32-byte identifier (e.g. an NFT mint pubkey as hex); must be non-zero.
 * @param tokenId - The NFT's token id; `0n` is valid.
 * @returns A canonical, frozen `Asset` with `assetType: ERC721` and `amount: 1n`.
 * @throws QuipSwapError `INVALID_ERC721_ASSET` if `target` is zero or the
 *   token id is negative; `INVALID_UNIVERSAL_ADDRESS` if malformed.
 * @see TermsLib.validateAsset
 * @example
 * ```ts
 * const punk = erc721Asset('0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB', 42n)
 * // punk.amount === 1n always
 * ```
 */
export function erc721Asset(target: Address | Hex32, tokenId: bigint): Asset {
  const universal = normalizeTokenTarget(target, 'INVALID_ERC721_ASSET', 'ERC-721')
  if (tokenId < 0n) {
    throw new QuipSwapError({
      code: 'INVALID_ERC721_ASSET',
      message: 'ERC-721 token id must be non-negative',
      details: {target, tokenId},
    })
  }
  return Object.freeze({assetType: AssetType.ERC721, target: universal, id: tokenId, amount: 1n})
}

/**
 * Builds an ERC-1155 asset (a quantity of one token id). EVM-only — Solana
 * has no `(contract, id)` token dimension (see `chains.ts`), and
 * `validateTerms` rejects ERC-1155 assets on SVM legs.
 *
 * Token id `0n` is explicitly VALID, mirroring the contract.
 *
 * @param target - The token identifier: a 20-byte EVM contract address or
 *   its 32-byte universal form; must be non-zero.
 * @param tokenId - The token id; `0n` is valid.
 * @param amount - Quantity of the token id; must be `> 0n`.
 * @returns A canonical, frozen `Asset` with `assetType: ERC1155`.
 * @throws QuipSwapError `INVALID_ERC1155_ASSET` if `target` is zero or the
 *   token id negative; `INVALID_UNIVERSAL_ADDRESS` if malformed;
 *   `ZERO_AMOUNT` if `amount <= 0n`.
 * @see TermsLib.validateAsset
 * @example
 * ```ts
 * const gameItems = erc1155Asset('0x495f947276749Ce646f68AC8c248420045cb7b5e', 7n, 25n)
 * ```
 */
export function erc1155Asset(target: Address | Hex32, tokenId: bigint, amount: bigint): Asset {
  const universal = normalizeTokenTarget(target, 'INVALID_ERC1155_ASSET', 'ERC-1155')
  if (tokenId < 0n) {
    throw new QuipSwapError({
      code: 'INVALID_ERC1155_ASSET',
      message: 'ERC-1155 token id must be non-negative',
      details: {target, tokenId},
    })
  }
  if (amount <= 0n) {
    throw new QuipSwapError({
      code: 'ZERO_AMOUNT',
      message: 'ERC-1155 asset amount must be greater than zero (contract: ZeroAmount)',
      details: {target, tokenId, amount},
    })
  }
  return Object.freeze({assetType: AssetType.ERC1155, target: universal, id: tokenId, amount})
}

/**
 * Validates an asset object received from an untrusted source (JSON, an
 * API, a database, another application).
 *
 * This is a faithful transcription of `TermsLib.validateAsset`:
 *
 * ```solidity
 * if (asset.amount == 0) revert ZeroAmount();
 * if (isNative && (!isZeroTarget || !isZeroId)) revert InvalidNativeAsset();
 * if (isERC20 && (isZeroTarget || !isZeroId)) revert InvalidERC20Asset();
 * // ERC721/ERC1155 token id 0 is valid; only a zero target is rejected
 * if (isERC721 && isZeroTarget) revert InvalidERC721Asset();
 * if (isERC1155 && isZeroTarget) revert InvalidERC1155Asset();
 * ```
 *
 * Chain-agnostic like the contract: a foreign (high-bit) 32-byte target is
 * structurally valid — locality is a separate, chain-aware check
 * (`assertEvmLocalLeg`). Unlike {@link erc721Asset}, this accepts any
 * non-zero ERC-721 amount, matching the contract exactly (validation must
 * not be stricter than the contract for objects that may already exist in
 * committed terms).
 *
 * @param asset - The asset to validate.
 * @throws QuipSwapError `ZERO_AMOUNT` | `INVALID_NATIVE_ASSET` |
 *   `INVALID_ERC20_ASSET` | `INVALID_ERC721_ASSET` | `INVALID_ERC1155_ASSET`
 *   | `INVALID_ASSET_TYPE`, each naming the matching contract error.
 * @see TermsLib.validateAsset
 * @example
 * ```ts
 * validateAsset(JSON.parse(payload, bigintReviver)) // throws on bad input
 * ```
 */
export function validateAsset(asset: Asset): void {
  if (
    asset.assetType !== AssetType.Native &&
    asset.assetType !== AssetType.ERC20 &&
    asset.assetType !== AssetType.ERC721 &&
    asset.assetType !== AssetType.ERC1155
  ) {
    // the contract cannot receive an out-of-range enum (ABI decoding reverts);
    // the SDK surfaces the same condition as a structured error
    throw new QuipSwapError({
      code: 'INVALID_ASSET_TYPE',
      message: `Unknown asset type ${String(asset.assetType)}; expected 0 (Native), 1 (ERC20), 2 (ERC721), or 3 (ERC1155)`,
      details: {asset},
    })
  }
  if (asset.amount <= 0n) {
    throw new QuipSwapError({
      code: 'ZERO_AMOUNT',
      message: 'Asset amount must be greater than zero for every asset type (contract: ZeroAmount)',
      details: {asset},
    })
  }
  if (!isUniversalValue(asset.target)) {
    throw new QuipSwapError({
      code: assetTypeErrorCode(asset.assetType),
      message: `Asset target ${String(asset.target)} is not a 32-byte universal identifier`,
      details: {asset},
    })
  }

  const isZeroTarget = BigInt(asset.target) === 0n
  const isZeroId = asset.id === 0n

  if (asset.assetType === AssetType.Native && (!isZeroTarget || !isZeroId)) {
    throw new QuipSwapError({
      code: 'INVALID_NATIVE_ASSET',
      message: 'Native asset must have zero target and zero id (contract: InvalidNativeAsset)',
      details: {asset},
    })
  }
  if (asset.assetType === AssetType.ERC20 && (isZeroTarget || !isZeroId)) {
    throw new QuipSwapError({
      code: 'INVALID_ERC20_ASSET',
      message: 'ERC-20 asset must have a non-zero target and id 0 (contract: InvalidERC20Asset)',
      details: {asset},
    })
  }
  // ERC721/ERC1155: token id 0 is valid; only a zero target is rejected
  if (asset.assetType === AssetType.ERC721 && isZeroTarget) {
    throw new QuipSwapError({
      code: 'INVALID_ERC721_ASSET',
      message: 'ERC-721 asset must have a non-zero target (contract: InvalidERC721Asset)',
      details: {asset},
    })
  }
  if (asset.assetType === AssetType.ERC1155 && isZeroTarget) {
    throw new QuipSwapError({
      code: 'INVALID_ERC1155_ASSET',
      message: 'ERC-1155 asset must have a non-zero target (contract: InvalidERC1155Asset)',
      details: {asset},
    })
  }
}

/** True when the value is well-formed 32-byte hex (foreign high bits allowed). */
function isUniversalValue(value: string): boolean {
  return typeof value === 'string' && /^0x[0-9a-fA-F]{64}$/.test(value)
}

/** Maps an asset type to its type-specific validation error code. */
function assetTypeErrorCode(
  assetType: AssetType,
): 'INVALID_NATIVE_ASSET' | 'INVALID_ERC20_ASSET' | 'INVALID_ERC721_ASSET' | 'INVALID_ERC1155_ASSET' {
  switch (assetType) {
    case AssetType.Native:
      return 'INVALID_NATIVE_ASSET'
    case AssetType.ERC20:
      return 'INVALID_ERC20_ASSET'
    case AssetType.ERC721:
      return 'INVALID_ERC721_ASSET'
    case AssetType.ERC1155:
      return 'INVALID_ERC1155_ASSET'
  }
}

/**
 * Normalizes a token target to its universal form, rejecting zero.
 *
 * @throws QuipSwapError with `code` when the target is zero;
 *   `INVALID_UNIVERSAL_ADDRESS` when it is neither a 20-byte address nor
 *   32-byte hex.
 */
function normalizeTokenTarget(
  target: Address | Hex32,
  code: 'INVALID_ERC20_ASSET' | 'INVALID_ERC721_ASSET' | 'INVALID_ERC1155_ASSET',
  label: string,
): Hex32 {
  const universal = toUniversalAddress(target)
  if (BigInt(universal) === 0n) {
    throw new QuipSwapError({
      code,
      message: `${label} asset target must be a non-zero token identifier`,
      details: {target},
    })
  }
  return universal
}

/**
 * Sums the native amounts in a side's terms — the amount of wei the
 * committer must escrow (before the commitment fee).
 *
 * Transcribes `TermsLib.totalNative`: only assets with
 * `assetType === Native` contribute; all other types are ignored.
 *
 * The exact commit transaction value is
 * `totalNative(party) + commitmentFee`, checked by the contract for strict
 * equality (`IncorrectNativeAmountReceived`) — see
 * {@link OmnibusClient.commit}, which re-reads the fee immediately before
 * simulating.
 *
 * @param terms - The side's terms (only `assets` is read).
 * @returns The sum of all native-asset amounts in wei (`0n` when none).
 * @see TermsLib.totalNative
 * @example
 * ```ts
 * totalNative({...terms, assets: [nativeAsset(5n), erc20Asset(token, 100n)]}) // 5n
 * ```
 */
export function totalNative(terms: Pick<Terms, 'assets'>): bigint {
  let total = 0n
  for (const asset of terms.assets) {
    if (asset.assetType === AssetType.Native) total += asset.amount
  }
  return total
}
