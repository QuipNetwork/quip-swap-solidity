/**
 * Core protocol types mirroring `src/TermsLib.sol` and
 * `src/interfaces/IOmnibus.sol` exactly.
 *
 * Every Solidity integer (`uint256`, token ids, amounts, chain ids,
 * timestamps, fees) is represented as `bigint` — never `number` — because
 * `uint256` exceeds `Number.MAX_SAFE_INTEGER`.
 */
import type {Address, Hex} from 'viem'

/**
 * The type of asset in a swap leg.
 *
 * Mirrors the Solidity `enum AssetType` (encoded as `uint8` in the ABI).
 * The numeric values MUST match the Solidity declaration order — they are
 * part of the terms digest, so a mismatch breaks hash agreement with the
 * contract.
 *
 * @see TermsLib (enum AssetType)
 */
export enum AssetType {
  /** Native chain currency (ETH on mainnet, etc.). */
  Native = 0,
  /** An ERC-20 fungible token. */
  ERC20 = 1,
  /** An ERC-721 non-fungible token (one specific token id). */
  ERC721 = 2,
  /** An ERC-1155 semi-fungible token (a quantity of one token id). */
  ERC1155 = 3,
}

/**
 * Lifecycle state of a hashlock in the Omnibus contract.
 *
 * Mirrors the Solidity `enum LockState`. Valid transitions (enforced
 * on-chain by `Omnibus._advanceLockTo`):
 *
 * ```text
 * Unused -> Free        (first same-chain commit)
 * Unused -> Committed   (cross-chain local commit)
 * Free   -> Committed   (second same-chain commit, other side)
 * Free   -> Spent       (reclaim of a half-committed same-chain swap)
 * Committed -> Spent    (claim or reclaim)
 * ```
 *
 * @see IOmnibus (enum LockState), Omnibus._advanceLockTo
 */
export enum LockState {
  /** Default — the lock has never been used. */
  Unused = 0,
  /** Same-chain only: one party has committed, waiting for the counterparty. */
  Free = 1,
  /** Ready for claim (same-chain: both committed; cross-chain: the single local commit). */
  Committed = 2,
  /** Terminal — claimed or reclaimed. */
  Spent = 3,
}

/**
 * An asset to be transferred as part of a swap.
 *
 * Mirrors the Solidity `struct Asset` field-for-field. All four fields are
 * part of the terms digest, so canonical field values matter: two assets
 * that move the same tokens but differ in any field produce different
 * digests and therefore different swaps.
 *
 * @see TermsLib (struct Asset)
 */
export interface Asset {
  /** The kind of asset; encoded as `uint8` in the ABI. */
  readonly assetType: AssetType
  /** Token contract address; MUST be the zero address for {@link AssetType.Native}. */
  readonly target: Address
  /**
   * Token id; used by ERC-721 and ERC-1155 and MUST be `0n` for Native and
   * ERC-20 (the contract rejects a non-zero id for ERC-20 with
   * `InvalidERC20Asset`). Token id `0n` is explicitly VALID for ERC-721 and
   * ERC-1155.
   */
  readonly id: bigint
  /**
   * Quantity in the token's base units (wei for native). MUST be greater
   * than zero for every asset type — including ERC-721, where the SDK
   * canonicalizes the value to `1n` (see {@link erc721Asset}).
   */
  readonly amount: bigint
}

/**
 * The terms for a single party (one "leg") of an Omnibus swap.
 *
 * Mirrors the Solidity `struct Terms` field-for-field. A swap consists of
 * two `Terms` whose lifecycle timestamps strictly interleave (see
 * {@link validateTermPairing}); the side with the earlier
 * `commitmentDeadline` is the PROPOSER and commits first.
 *
 * @see TermsLib (struct Terms)
 */
export interface Terms {
  /**
   * The chain id where THIS side's assets are held and escrowed. The two
   * sides may name different chains (cross-chain swap) or the same chain
   * (same-chain swap). Must be non-zero.
   */
  readonly chainId: bigint
  /**
   * The address allowed to submit and fund THIS side's commit. `commit`
   * enforces `msg.sender == sender`, so this field is part of both the
   * terms digest and the runtime authorization boundary. Must be non-zero.
   */
  readonly sender: Address
  /**
   * The address that receives this side's own assets back if the swap is
   * reclaimed instead of claimed. Must be non-zero.
   */
  readonly reclaimRecipient: Address
  /**
   * The address that receives the COUNTERPARTY's assets when the swap is
   * claimed — not this side's own assets. Must be non-zero.
   */
  readonly recipient: Address
  /**
   * Unix timestamp (seconds) at and after which this side may no longer
   * commit. Also the instant the counterparty-taker's commit window opens
   * when this side proposes. Must be non-zero.
   */
  readonly commitmentDeadline: bigint
  /**
   * Unix timestamp (seconds) at and after which claiming gated by this
   * side's claim schedule is forbidden. Must be strictly greater than
   * `commitmentDeadline`.
   */
  readonly claimDeadline: bigint
  /**
   * Unix timestamp (seconds) at and after which this side's escrowed assets
   * may be reclaimed to `reclaimRecipient`. Must be strictly greater than
   * `claimDeadline`.
   */
  readonly reclaimRelease: bigint
  /** The assets this side escrows. Must be non-empty and each asset valid. */
  readonly assets: readonly Asset[]
}

/** A 32-byte hex value (`0x` + 64 hex chars), e.g. a secret, lock, or digest. */
export type Hex32 = Hex

/**
 * A freshly generated hashlock pair.
 *
 * Secrecy lifecycle:
 * - `lock` may be shared freely — it is published on-chain at commit time.
 * - `secret` MUST remain private until the holder claims; the `Claim` event
 *   reveals it publicly.
 * - Revealing the secret early lets anyone in the proposer-claim window
 *   claim, compromising a cross-chain flow.
 * - Losing the secret makes claiming impossible; the assets can then only
 *   be recovered via reclaim after `reclaimRelease`.
 */
export interface SecretLockPair {
  /** The 32-byte preimage. Keep private until claim. */
  readonly secret: Hex32
  /** `keccak256(secret)` — safe to share. */
  readonly lock: Hex32
}
