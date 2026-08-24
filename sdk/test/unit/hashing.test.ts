/**
 * Hashing unit tests (pure determinism and sensitivity properties).
 *
 * These tests prove the digest is sensitive to every input field and that
 * canonical ordering is side-order independent. They do NOT prove
 * Solidity equivalence — `test/integration/differential.test.ts` does that
 * against the deployed `TermsLibHarness`/`OmnibusHarness` oracles.
 *
 * Parallels `test/TermsLib/behaviors/digestTerms.t.sol` and
 * `digestTermsCanonically.t.sol`.
 */
import {describe, expect, it} from 'vitest'
import {erc20Asset, nativeAsset} from '../../src/assets.js'
import {concat, keccak256} from 'viem'
import {digestTerms, digestTermsCanonically, generateLock, swapId, swapIdFromDigest} from '../../src/hashing.js'
import type {Terms} from '../../src/types.js'
import {aliceTerms, BOB, bobTerms, CHAIN_A, FOUNDRY_LOCK, FOUNDRY_SECRET, withOverrides} from '../helpers/fixtures.js'

const TOKEN = '0x1000000000000000000000000000000000000001' as const

const base = aliceTerms(CHAIN_A, [nativeAsset(10n), erc20Asset(TOKEN, 100n)])

describe('digestTerms', () => {
  it('is deterministic: same input, same digest', () => {
    expect(digestTerms(base)).toBe(digestTerms({...base, assets: [...base.assets]}))
  })

  it('every one of the seven Terms fields affects the digest', () => {
    const variants: Partial<Terms>[] = [
      {chainId: base.chainId + 1n},
      {reclaimRecipient: BOB},
      {recipient: BOB},
      {commitmentDeadline: base.commitmentDeadline + 1n},
      {claimDeadline: base.claimDeadline + 1n},
      {reclaimRelease: base.reclaimRelease + 1n},
      {assets: [nativeAsset(10n)]},
    ]
    const baseline = digestTerms(base)
    for (const overrides of variants) {
      expect(digestTerms(withOverrides(base, overrides)), JSON.stringify(Object.keys(overrides))).not.toBe(baseline)
    }
  })

  it('asset target, id, and amount each affect the digest', () => {
    const baseline = digestTerms(base)
    const otherToken = '0x2000000000000000000000000000000000000002' as const
    expect(digestTerms(withOverrides(base, {assets: [nativeAsset(10n), erc20Asset(otherToken, 100n)]}))).not.toBe(
      baseline,
    )
    expect(digestTerms(withOverrides(base, {assets: [nativeAsset(10n), erc20Asset(TOKEN, 101n)]}))).not.toBe(baseline)
    // id sensitivity via ERC-1155-style raw asset (builders pin ERC-20 id to 0)
    const withId = withOverrides(base, {
      assets: [nativeAsset(10n), {assetType: 3, target: TOKEN, id: 1n, amount: 100n}],
    })
    const withOtherId = withOverrides(base, {
      assets: [nativeAsset(10n), {assetType: 3, target: TOKEN, id: 2n, amount: 100n}],
    })
    expect(digestTerms(withId)).not.toBe(digestTerms(withOtherId))
  })

  it('asset ORDER affects the single-side digest', () => {
    const forward = withOverrides(base, {assets: [nativeAsset(10n), erc20Asset(TOKEN, 100n)]})
    const reversed = withOverrides(base, {assets: [erc20Asset(TOKEN, 100n), nativeAsset(10n)]})
    expect(digestTerms(forward)).not.toBe(digestTerms(reversed))
  })
})

describe('digestTermsCanonically', () => {
  const alice = aliceTerms(CHAIN_A)
  const bob = bobTerms(CHAIN_A)

  it('is order-independent across sides', () => {
    expect(digestTermsCanonically(alice, bob)).toBe(digestTermsCanonically(bob, alice))
  })

  it('differs from the single-side digests', () => {
    const canonical = digestTermsCanonically(alice, bob)
    expect(canonical).not.toBe(digestTerms(alice))
    expect(canonical).not.toBe(digestTerms(bob))
  })

  it('changes when either side changes', () => {
    const baseline = digestTermsCanonically(alice, bob)
    expect(digestTermsCanonically(withOverrides(alice, {chainId: alice.chainId + 1n}), bob)).not.toBe(baseline)
    expect(digestTermsCanonically(alice, withOverrides(bob, {chainId: bob.chainId + 1n}))).not.toBe(baseline)
  })
})

describe('generateLock', () => {
  it('reproduces the Foundry suite vector (oracle: cast keccak, not the SDK)', () => {
    // SECRET = keccak256('secret'), LOCK = keccak256(SECRET) — both computed
    // with Solidity tooling and hardcoded in the fixtures
    expect(generateLock(FOUNDRY_SECRET)).toBe(FOUNDRY_LOCK)
  })

  it('reproduces the known keccak256 of 32 zero bytes', () => {
    expect(generateLock(`0x${'00'.repeat(32)}`)).toBe(
      '0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563',
    )
  })

  it('rejects wrong-length secrets', () => {
    expect(() => generateLock('0x1234' as never)).toThrow('32-byte')
    expect(() => generateLock(`0x${'00'.repeat(33)}` as never)).toThrow('32-byte')
  })

  it('rejects invalid hex', () => {
    expect(() => generateLock(`0x${'zz'.repeat(32)}` as never)).toThrow('32-byte')
    expect(() => generateLock('not hex at all' as never)).toThrow('32-byte')
  })
})

describe('swapId', () => {
  const alice = aliceTerms(CHAIN_A)
  const bob = bobTerms(CHAIN_A)

  it('is keccak256 of the packed lock + canonical digest (Omnibus._swapId transcription)', () => {
    const expected = keccak256(concat([FOUNDRY_LOCK, digestTermsCanonically(alice, bob)]))
    expect(swapId(FOUNDRY_LOCK, alice, bob)).toBe(expected)
  })

  it('equals swapIdFromDigest over the canonical digest', () => {
    expect(swapId(FOUNDRY_LOCK, alice, bob)).toBe(swapIdFromDigest(FOUNDRY_LOCK, digestTermsCanonically(alice, bob)))
  })

  it('is order-independent across sides', () => {
    expect(swapId(FOUNDRY_LOCK, alice, bob)).toBe(swapId(FOUNDRY_LOCK, bob, alice))
  })

  it('changes with the lock', () => {
    const otherLock = generateLock(`0x${'11'.repeat(32)}`)
    expect(swapId(otherLock, alice, bob)).not.toBe(swapId(FOUNDRY_LOCK, alice, bob))
  })

  it('changes when either side changes — an unrelated pairing occupies its own slot', () => {
    const dust = withOverrides(bob, {assets: [nativeAsset(1n)]})
    expect(swapId(FOUNDRY_LOCK, alice, dust)).not.toBe(swapId(FOUNDRY_LOCK, alice, bob))
  })
})
