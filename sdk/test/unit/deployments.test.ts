/**
 * Deployment-resolution unit tests.
 *
 * Three concerns:
 * - SHIPPED STATE: the registry resolves exactly the chains recorded in
 *   `src/deployments.json` and nothing else, and each row carries the fields
 *   the SDK promises (address, version label, wallet factory).
 * - DRIFT: rows sharing a version label must share an address, and rows with
 *   different labels must not — the property that lets one chain redeploy
 *   without moving the others.
 * - MECHANISM: `resolveDeployment` still throws `UNKNOWN_DEPLOYMENT` for an
 *   unrecorded chain, and an override still resolves and still validates.
 */
import {getAddress} from 'viem'
import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {QuipSwapError} from '../../src/errors.js'
import {knownDeployments, registryRows, resolveDeployment} from '../../src/deployments.js'
import type {OmnibusDeployment} from '../../src/deployments.js'
import registry from '../../src/deployments.json'

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

const BASE_MAINNET = 8453n
const BASE_SEPOLIA = 84_532n
const OP_SEPOLIA = 11_155_420n

/** The canonical quip WalletFactory proxy — the same address on every chain. */
/** Per family, mirroring DeployConstants.MAINNET_WALLET_FACTORY / TESTNET_WALLET_FACTORY. */
const CANONICAL_WALLET_FACTORY: Record<string, Address> = {
  [BASE_MAINNET.toString()]: '0xA2B2F71456a799FCf4EF7A3111c4B96b3e928cc8',
  [BASE_SEPOLIA.toString()]: '0xA2B2F71456a799FCf4EF7A3111c4B96b3e928cc8',
  [OP_SEPOLIA.toString()]: '0xA2B2F71456a799FCf4EF7A3111c4B96b3e928cc8',
}

describe('resolveDeployment — shipped state', () => {
  it('exposes every registry row, live or not', () => {
    expect(registryRows.map(r => r.chainId).sort()).toEqual(registry.deployments.map(r => BigInt(r.chainId)).sort())
  })

  it('registers exactly the LIVE chains as known deployments', () => {
    // Assert exact membership, not just the count: a wrong chain id would
    // otherwise slip through while the size still matched.
    const live = registry.deployments.filter(r => r.deployed).map(r => BigInt(r.chainId))
    expect([...knownDeployments.keys()].sort()).toEqual(live.sort())
  })

  it('carries address, version and wallet factory on every live row', () => {
    for (const row of registry.deployments.filter(r => r.deployed)) {
      const resolved = resolveDeployment(BigInt(row.chainId))
      expect(resolved.omnibusAddress).toBe(row.omnibus)
      expect(resolved.version).toBe(row.version)
      expect(resolved.walletFactory).toBe(row.walletFactory)
      expect(resolved.deployed).toBe(true)
    }
  })

  it('throws UNKNOWN_DEPLOYMENT for any unrecorded chain without an override', () => {
    expect(codeOf(() => resolveDeployment(1n))).toBe('UNKNOWN_DEPLOYMENT')
    expect(codeOf(() => resolveDeployment(42_161n))).toBe('UNKNOWN_DEPLOYMENT')
  })

  /**
   * A recorded-but-not-live row must never be handed out. This is the failure
   * that started all of this: an Omnibus IS live at the testnet addresses, but
   * wired to a non-canonical WalletFactory, so the wallet route rejects valid
   * wallets with `NotQuipWallet`. Returning the address would launder that into
   * every consumer.
   */
  it('refuses a recorded chain that is not live, and says why', () => {
    for (const row of registry.deployments.filter(r => !r.deployed)) {
      const chainId = BigInt(row.chainId)
      expect(codeOf(() => resolveDeployment(chainId))).toBe('UNKNOWN_DEPLOYMENT')
      expect(() => resolveDeployment(chainId)).toThrow(/NOT live/)
    }
  })

  it('an explicit override still reaches a not-live chain', () => {
    for (const row of registry.deployments.filter(r => !r.deployed)) {
      const chainId = BigInt(row.chainId)
      const override: OmnibusDeployment = {chainId, omnibusAddress: row.omnibus as Address}
      expect(resolveDeployment(chainId, override)).toEqual(override)
    }
  })
})

describe('registry drift — version label governs the address', () => {
  it('rows sharing a version label share an address', () => {
    const byVersion = new Map<string, Set<string>>()
    for (const row of registry.deployments) {
      const seen = byVersion.get(row.version) ?? new Set<string>()
      seen.add(row.omnibus)
      byVersion.set(row.version, seen)
    }
    for (const [version, addresses] of byVersion) {
      expect(addresses.size, `version ${version} maps to more than one address`).toBe(1)
    }
  })

  it('distinct version labels do not share an address', () => {
    const byAddress = new Map<string, Set<string>>()
    for (const row of registry.deployments) {
      const seen = byAddress.get(row.omnibus) ?? new Set<string>()
      seen.add(row.version)
      byAddress.set(row.omnibus, seen)
    }
    for (const [address, versions] of byAddress) {
      expect(versions.size, `address ${address} is claimed by more than one version`).toBe(1)
    }
  })

  /**
   * FULL COVERAGE, asserted rather than commented so regressions cannot hide.
   * 84532 and 11155420 originally shipped wired to a testnet-only WalletFactory
   * duplicate (breaking the wallet commit route with `NotQuipWallet`) and were
   * recorded not-live; both were redeployed under a bumped version label. Every
   * registry row must now be live under its family's canonical factory — if a
   * future `make sync-registry` demotes a chain, this failure is the alarm.
   * (It is also red, by design, between a label bump and the redeploy.)
   */
  it('records every chain as live under the canonical wallet factory', () => {
    for (const chainId of [BASE_MAINNET, BASE_SEPOLIA, OP_SEPOLIA]) {
      const row = registryRows.find(r => r.chainId === chainId)
      expect(row?.deployed, `chain ${chainId} is not live`).toBe(true)
      expect(resolveDeployment(chainId).walletFactory).toBe(CANONICAL_WALLET_FACTORY[chainId.toString()])
    }
  })
})

describe('resolveDeployment — overrides', () => {
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

  it('an override wins even for a chain that is in the registry', () => {
    const override: OmnibusDeployment = {chainId: BASE_MAINNET, omnibusAddress: OVERRIDE_ADDR}
    expect(resolveDeployment(BASE_MAINNET, override)).toEqual(override)
  })
})
