/**
 * Universal (bytes32) address handling.
 *
 * The contract identifies tokens and recipients with `bytes32` so a swap leg
 * on a non-EVM chain (e.g. Solana) can carry a full 32-byte pubkey. EVM
 * addresses occupy the LOW 20 bytes — `bytes32(uint256(uint160(addr)))`,
 * matching `abi.encode(address)` — so terms digests for EVM-only swaps are
 * identical to the pre-widening encoding. NEVER left-align an address into
 * the high bytes; that changes every digest.
 *
 * Which fields must be EVM-narrowable is a per-chain question:
 * - `Asset.target` and `Terms.reclaimRecipient` live on the LEG's OWN chain
 *   (`terms.chainId`).
 * - `Terms.recipient` lives on the COUNTERPARTY's chain — it receives the
 *   counterparty's assets at claim. A local EVM leg swapping against Solana
 *   legitimately carries a Solana pubkey as its `recipient`.
 *
 * @see TermsLib.toEvmAddress, TermsLib.validateLocalLeg
 */
import {getAddress, isAddress, isHex, pad, sliceHex} from 'viem'
import type {Address} from 'viem'
import {QuipSwapError} from './errors.js'
import type {Hex32} from './types.js'

/** The 32-byte zero value — the universal form of the zero address / native target. */
export const ZERO_BYTES32: Hex32 = '0x0000000000000000000000000000000000000000000000000000000000000000'

/**
 * Widens an EVM address into its universal bytes32 form (low 20 bytes).
 *
 * Mirrors the Solidity convention `bytes32(uint256(uint160(addr)))`: the
 * address occupies the LOW 20 bytes, upper 12 bytes zero — the same word
 * `abi.encode(address)` produces.
 *
 * @param address - A well-formed EVM address.
 * @returns The 32-byte identifier (lowercased hex).
 * @throws QuipSwapError `INVALID_UNIVERSAL_ADDRESS` if `address` is not a
 *   well-formed EVM address.
 * @example
 * ```ts
 * evmToBytes32('0x000000000000000000000000000000000000a11ce'.slice(0, 42))
 * // '0x00000000000000000000000000000000000000000000000000000000000a11ce'
 * ```
 */
export function evmToBytes32(address: Address): Hex32 {
  if (!isAddress(address, {strict: false})) {
    throw new QuipSwapError({
      code: 'INVALID_UNIVERSAL_ADDRESS',
      message: `Cannot widen ${String(address)} to bytes32: not a well-formed EVM address`,
      details: {address},
    })
  }
  // pad() left-pads by default — the uint alignment; right-padding would be
  // the digest-breaking bytes32(bytes20(addr)) form
  return pad(address.toLowerCase() as Address, {size: 32})
}

/**
 * Narrows a universal bytes32 identifier back to an EVM address.
 *
 * Mirrors `TermsLib.toEvmAddress`: any of the upper 12 bytes set marks a
 * foreign-chain identifier (e.g. a Solana pubkey) that cannot exist on an
 * EVM chain.
 *
 * @param value - The 32-byte identifier.
 * @returns The checksummed EVM address from the low 20 bytes.
 * @throws QuipSwapError `NOT_EVM_ADDRESS` when any upper byte is non-zero
 *   (contract: NotEvmAddress); `INVALID_UNIVERSAL_ADDRESS` when `value` is
 *   not 32-byte hex.
 * @see TermsLib.toEvmAddress
 */
export function bytes32ToEvm(value: Hex32): Address {
  assertUniversalAddress(value)
  if (!isEvmBytes32(value)) {
    throw new QuipSwapError({
      code: 'NOT_EVM_ADDRESS',
      message:
        `${value} does not fit an EVM address (upper 12 bytes are non-zero); ` +
        'it identifies an account on a non-EVM chain (contract: NotEvmAddress)',
      details: {value},
    })
  }
  return getAddress(sliceHex(value, 12))
}

/**
 * True when a 32-byte identifier fits an EVM address (upper 12 bytes zero).
 *
 * Does not throw on malformed input — returns `false` for anything that is
 * not 32-byte hex.
 */
export function isEvmBytes32(value: string): value is Hex32 {
  if (!isHex(value, {strict: true}) || value.length !== 66) return false
  return BigInt(value) >> 160n === 0n
}

/**
 * Normalizes an address-like value into the universal bytes32 form.
 *
 * Accepts either a 20-byte EVM address (widened via {@link evmToBytes32}) or
 * an already-32-byte identifier (passed through lowercased). This is the
 * input normalizer used by the terms/asset builders so callers can supply
 * plain EVM addresses or full Solana-style pubkeys interchangeably.
 *
 * Note on Solana pubkeys: they are raw 32 bytes — pass them as 32-byte hex.
 * The SDK deliberately has no base58 decoder yet (viem-only dependency
 * surface); add one alongside the Solana program integration.
 *
 * @param value - A 20-byte EVM address or 32-byte universal identifier.
 * @returns The 32-byte identifier (lowercased hex).
 * @throws QuipSwapError `INVALID_UNIVERSAL_ADDRESS` for any other shape.
 */
export function toUniversalAddress(value: Address | Hex32): Hex32 {
  if (typeof value === 'string' && isHex(value, {strict: true})) {
    if (value.length === 42) return evmToBytes32(value as Address)
    if (value.length === 66) return value.toLowerCase() as Hex32
  }
  throw new QuipSwapError({
    code: 'INVALID_UNIVERSAL_ADDRESS',
    message:
      `Cannot normalize ${String(value)} to a universal address: expected a 20-byte EVM address ` +
      '(42 hex chars) or a 32-byte identifier (66 hex chars)',
    details: {value},
  })
}

/** Asserts a value is 32-byte hex; the shared shape gate for universal addresses. */
function assertUniversalAddress(value: string): asserts value is Hex32 {
  if (!isHex(value, {strict: true}) || value.length !== 66) {
    throw new QuipSwapError({
      code: 'INVALID_UNIVERSAL_ADDRESS',
      message: `Expected a 32-byte universal address (0x + 64 hex chars); received ${
        typeof value === 'string' ? `${value.length} chars` : typeof value
      }`,
      details: {value},
    })
  }
}
