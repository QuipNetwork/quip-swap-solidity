/**
 * Secret generation unit tests.
 *
 * Covers: 32-byte shape of generated secrets and locks, lock/secret
 * consistency, basic non-repetition, external secret validation, and the
 * Solidity-compatible fixed-secret vector.
 */
import {describe, expect, it} from 'vitest'
import {generateLock} from '../../src/hashing.js'
import {generateSecret, secretToPair} from '../../src/secrets.js'
import {FOUNDRY_LOCK, FOUNDRY_SECRET} from '../helpers/fixtures.js'

const HEX32 = /^0x[0-9a-f]{64}$/

describe('generateSecret', () => {
  it('produces a 32-byte secret and a 32-byte lock', () => {
    const {secret, lock} = generateSecret()
    expect(secret).toMatch(HEX32)
    expect(lock).toMatch(HEX32)
  })

  it('lock is keccak256 of the secret', () => {
    const {secret, lock} = generateSecret()
    expect(generateLock(secret)).toBe(lock)
  })

  it('does not repeat across invocations (CSPRNG sanity check)', () => {
    const seen = new Set<string>()
    for (let i = 0; i < 64; i++) seen.add(generateSecret().secret)
    expect(seen.size).toBe(64)
  })

  it('returns a frozen pair', () => {
    expect(Object.isFrozen(generateSecret())).toBe(true)
  })
})

describe('secretToPair', () => {
  it('derives the Solidity-compatible lock for the Foundry fixed secret', () => {
    expect(secretToPair(FOUNDRY_SECRET).lock).toBe(FOUNDRY_LOCK)
  })

  it('rejects invalid secret length', () => {
    expect(() => secretToPair('0x00')).toThrow('32-byte')
  })

  it('rejects invalid hex', () => {
    expect(() => secretToPair(`0x${'gg'.repeat(32)}`)).toThrow('32-byte')
  })

  it('never echoes the secret value in errors', () => {
    try {
      secretToPair('0xdeadbeef')
      expect.unreachable()
    } catch (error) {
      expect((error as Error).message).not.toContain('deadbeef')
    }
  })
})
