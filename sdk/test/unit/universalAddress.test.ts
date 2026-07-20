/**
 * Universal (bytes32) address handling unit tests.
 *
 * Covers: low-20-byte alignment of `evmToBytes32` (the digest-critical
 * convention — left-padding, never right), narrowing round-trips, foreign
 * (high-bit) rejection, shape validation, and the `toUniversalAddress`
 * normalizer both builders and terms construction rely on.
 *
 * Parallels `test/TermsLib/behaviors/toEvmAddress.t.sol`.
 */
import {getAddress} from 'viem'
import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {QuipSwapError} from '../../src/errors.js'
import {
  ZERO_BYTES32,
  bytes32ToEvm,
  evmToBytes32,
  isEvmBytes32,
  toUniversalAddress,
} from '../../src/universalAddress.js'
import {SOLANA_PUBKEY} from '../helpers/fixtures.js'

const TOKEN: Address = '0x1000000000000000000000000000000000000001'

function codeOf(fn: () => unknown): string {
  try {
    fn()
  } catch (error) {
    if (error instanceof QuipSwapError) return error.code
    throw error
  }
  throw new Error('expected the call to throw a QuipSwapError')
}

describe('evmToBytes32', () => {
  it('left-pads: the address occupies the LOW 20 bytes (uint alignment)', () => {
    // the load-bearing convention: matches abi.encode(address); right-padding
    // (bytes20 alignment) would change every terms digest
    expect(evmToBytes32(TOKEN)).toBe('0x0000000000000000000000001000000000000000000000000000000000000001')
  })

  it('widens the zero address to ZERO_BYTES32', () => {
    expect(evmToBytes32('0x0000000000000000000000000000000000000000')).toBe(ZERO_BYTES32)
  })

  it('rejects malformed addresses', () => {
    expect(codeOf(() => evmToBytes32('0x1234' as Address))).toBe('INVALID_UNIVERSAL_ADDRESS')
    expect(codeOf(() => evmToBytes32('not-an-address' as Address))).toBe('INVALID_UNIVERSAL_ADDRESS')
  })
})

describe('bytes32ToEvm', () => {
  it('round-trips with evmToBytes32 (checksummed result)', () => {
    expect(bytes32ToEvm(evmToBytes32(TOKEN))).toBe(getAddress(TOKEN))
  })

  it('narrows the zero value to the zero address', () => {
    expect(bytes32ToEvm(ZERO_BYTES32)).toBe('0x0000000000000000000000000000000000000000')
  })

  it('rejects foreign identifiers — any of the upper 12 bytes set (contract: NotEvmAddress)', () => {
    expect(codeOf(() => bytes32ToEvm(SOLANA_PUBKEY))).toBe('NOT_EVM_ADDRESS')
    // bit 160 is the first bit outside an EVM address
    const boundary = `0x0000000000000000000000010000000000000000000000000000000000000000` as const
    expect(codeOf(() => bytes32ToEvm(boundary))).toBe('NOT_EVM_ADDRESS')
  })

  it('rejects values that are not 32-byte hex', () => {
    expect(codeOf(() => bytes32ToEvm(TOKEN as never))).toBe('INVALID_UNIVERSAL_ADDRESS')
  })
})

describe('isEvmBytes32', () => {
  it('true for EVM-narrowable values including zero', () => {
    expect(isEvmBytes32(ZERO_BYTES32)).toBe(true)
    expect(isEvmBytes32(evmToBytes32(TOKEN))).toBe(true)
  })

  it('false for foreign identifiers and malformed input (never throws)', () => {
    expect(isEvmBytes32(SOLANA_PUBKEY)).toBe(false)
    expect(isEvmBytes32(TOKEN)).toBe(false) // 20-byte, not 32-byte
    expect(isEvmBytes32('garbage')).toBe(false)
  })
})

describe('toUniversalAddress', () => {
  it('widens a 20-byte address', () => {
    expect(toUniversalAddress(TOKEN)).toBe(evmToBytes32(TOKEN))
  })

  it('passes a 32-byte identifier through (lowercased)', () => {
    expect(toUniversalAddress(SOLANA_PUBKEY)).toBe(SOLANA_PUBKEY.toLowerCase())
  })

  it('rejects every other shape', () => {
    expect(codeOf(() => toUniversalAddress('0x1234' as Address))).toBe('INVALID_UNIVERSAL_ADDRESS')
    expect(codeOf(() => toUniversalAddress('' as Address))).toBe('INVALID_UNIVERSAL_ADDRESS')
  })
})
