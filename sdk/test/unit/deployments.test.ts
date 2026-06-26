/**
 * Deployment-resolution unit tests.
 *
 * Two concerns:
 * - SHIPPED STATE (placeholder address + empty verified-chain set):
 *   `resolveDeployment` throws `UNKNOWN_DEPLOYMENT` for every chain without an
 *   override; an override still resolves and still validates. This pins the
 *   "no false defaults ship" guarantee while the placeholder stands.
 * - MECHANISM (so enabling a chain later is safe): a LOCAL registry built the
 *   same way (canonical address + a verified-chain set) returns the canonical
 *   address for a listed chain and nothing for an unlisted one — exercised
 *   without enabling any real chain in source.
 */
import {getAddress} from 'viem'
import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {QuipSwapError} from '../../src/errors.js'
import {knownDeployments, OMNIBUS_CREATE3_ADDRESS, resolveDeployment} from '../../src/deployments.js'
import type {OmnibusDeployment} from '../../src/deployments.js'

const OVERRIDE_ADDR: Address = getAddress('0x00000000000000000000000000000000000ab1ce')

function codeOf(fn: () => unknown): string {
  try {
    fn()
  } catch (error) {
    if (error instanceof QuipSwapError) return error.code
    throw error
  }
  throw new Error('expected the call to throw a QuipSwapError')
}

describe('resolveDeployment — shipped (placeholder) state', () => {
  it('ships an empty registry (no false defaults while the placeholder stands)', () => {
    expect(knownDeployments.size).toBe(0)
    // the canonical address is still the zero placeholder — not a real default
    expect(OMNIBUS_CREATE3_ADDRESS).toBe('0x0000000000000000000000000000000000000000')
  })

  it('throws UNKNOWN_DEPLOYMENT for any chain without an override', () => {
    expect(codeOf(() => resolveDeployment(8453n))).toBe('UNKNOWN_DEPLOYMENT')
    expect(codeOf(() => resolveDeployment(1n))).toBe('UNKNOWN_DEPLOYMENT')
  })

  it('resolves a valid override', () => {
    const override: OmnibusDeployment = {chainId: 8453n, omnibusAddress: OVERRIDE_ADDR}
    expect(resolveDeployment(8453n, override)).toEqual(override)
  })

  it('rejects an override with a zero/invalid address', () => {
    expect(codeOf(() => resolveDeployment(8453n, {chainId: 8453n, omnibusAddress: `0x${'00'.repeat(20)}`}))).toBe(
      'UNKNOWN_DEPLOYMENT',
    )
    expect(
      codeOf(() => resolveDeployment(8453n, {chainId: 8453n, omnibusAddress: 'not-an-address' as Address})),
    ).toBe('UNKNOWN_DEPLOYMENT')
  })

  it('rejects an override whose chainId does not match the requested chain', () => {
    expect(codeOf(() => resolveDeployment(8453n, {chainId: 42161n, omnibusAddress: OVERRIDE_ADDR}))).toBe(
      'UNKNOWN_DEPLOYMENT',
    )
  })
})

describe('resolveDeployment — mechanism (local verified set, no real chain enabled)', () => {
  // mirror the source derivation: canonical address + a set of verified chains
  const CANONICAL: Address = getAddress('0x000000000000000000000000000000000000c3c3')
  const VERIFIED = new Set<bigint>([31337n])
  const localRegistry: ReadonlyMap<bigint, OmnibusDeployment> = new Map(
    [...VERIFIED].map(chainId => [chainId, {chainId, omnibusAddress: CANONICAL}]),
  )

  /** resolveDeployment's logic, but against the local registry (proves enabling a chain works). */
  function resolveLocal(chainId: bigint, override?: OmnibusDeployment): OmnibusDeployment {
    if (override !== undefined) return resolveDeployment(chainId, override)
    const known = localRegistry.get(chainId)
    if (known === undefined) throw new QuipSwapError({code: 'UNKNOWN_DEPLOYMENT', message: `no deployment for ${chainId}`})
    return known
  }

  it('returns the canonical address for a verified chain', () => {
    expect(resolveLocal(31337n)).toEqual({chainId: 31337n, omnibusAddress: CANONICAL})
  })

  it('throws for an unlisted chain', () => {
    expect(codeOf(() => resolveLocal(999n))).toBe('UNKNOWN_DEPLOYMENT')
  })

  it('an override wins even for a chain that is in the verified set', () => {
    const override: OmnibusDeployment = {chainId: 31337n, omnibusAddress: OVERRIDE_ADDR}
    expect(resolveLocal(31337n, override)).toEqual(override)
  })
})
