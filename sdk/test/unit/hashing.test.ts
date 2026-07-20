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
import {toHex} from 'viem'
import {describe, expect, it} from 'vitest'
import {erc20Asset, nativeAsset} from '../../src/assets.js'
import {SOLANA_MAINNET_CHAIN_ID} from '../../src/chains.js'
import {digestTerms, digestTermsCanonically, generateLock} from '../../src/hashing.js'
import type {Terms} from '../../src/types.js'
import {evmToBytes32} from '../../src/universalAddress.js'
import {
  aliceTerms,
  BOB,
  bobTerms,
  CHAIN_A,
  FOUNDRY_LOCK,
  FOUNDRY_SECRET,
  SOLANA_MINT,
  SOLANA_PUBKEY,
  withOverrides,
} from '../helpers/fixtures.js'

const TOKEN = '0x1000000000000000000000000000000000000001' as const

const base = aliceTerms(CHAIN_A, [nativeAsset(10n), erc20Asset(TOKEN, 100n)])

describe('digestTerms', () => {
  it('is deterministic: same input, same digest', () => {
    expect(digestTerms(base)).toBe(digestTerms({...base, assets: [...base.assets]}))
  })

  it('every one of the eight Terms fields affects the digest', () => {
    const variants: Partial<Terms>[] = [
      {chainId: base.chainId + 1n},
      {reclaimRecipient: evmToBytes32(BOB)},
      {recipient: evmToBytes32(BOB)},
      {commitmentDeadline: base.commitmentDeadline + 1n},
      {claimDeadline: base.claimDeadline + 1n},
      {reclaimRelease: base.reclaimRelease + 1n},
      {optimistic: !base.optimistic},
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
      assets: [nativeAsset(10n), {assetType: 3, target: evmToBytes32(TOKEN), id: 1n, amount: 100n}],
    })
    const withOtherId = withOverrides(base, {
      assets: [nativeAsset(10n), {assetType: 3, target: evmToBytes32(TOKEN), id: 2n, amount: 100n}],
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

describe('pinned digest vectors (Solidity ↔ SDK parity)', () => {
  // Field-for-field mirrors of the fixtures in test/TermsLib/TermsLib.t.sol;
  // the pinned digests are the SAME constants as EVM_VECTOR_DIGEST /
  // SOLANA_VECTOR_DIGEST / CANONICAL_PAIR_DIGEST there. The pin is the
  // absolute cross-implementation anchor: never change a fixture or pin on
  // one side without the other — a mismatch is digest drift, not a test fix.

  const evmVector: Terms = {
    chainId: 31_337n,
    reclaimRecipient: toHex(0xa11cen, {size: 32}),
    recipient: toHex(0xb0bn, {size: 32}),
    commitmentDeadline: 1000n,
    claimDeadline: 2000n,
    reclaimRelease: 3000n,
    optimistic: false,
    assets: [nativeAsset(10n ** 18n)],
  }

  const solanaVector: Terms = {
    chainId: SOLANA_MAINNET_CHAIN_ID,
    reclaimRecipient: SOLANA_PUBKEY,
    recipient: toHex(0xaan, {size: 32}),
    commitmentDeadline: 1500n,
    claimDeadline: 2500n,
    reclaimRelease: 3500n,
    optimistic: false,
    assets: [erc20Asset(SOLANA_MINT, 1_000_000_000n)],
  }

  it('reproduces the pinned all-EVM vector digest', () => {
    expect(digestTerms(evmVector)).toBe('0xba4a8385b187ea45d0feb380b65b7532b94f11d9bb2008d4b78fa12e39fc0b79')
  })

  it('reproduces the pinned Solana-styled vector digest (high-bit bytes32 range)', () => {
    expect(digestTerms(solanaVector)).toBe('0x8af3881416101f8354049a0f961f624ccc5b1759141357463856f5c0e0ee9528')
  })

  it('reproduces the pinned canonical pair digest, order-independently', () => {
    const pinned = '0xbf1f3cf7a5b7fda84a14091f47f7b963c57a04d1bab8578927cfa6c10e09fbb7'
    expect(digestTermsCanonically(evmVector, solanaVector)).toBe(pinned)
    expect(digestTermsCanonically(solanaVector, evmVector)).toBe(pinned)
  })

  it('binds the foreign upper bits: a truncated pubkey digests differently', () => {
    const truncatedMint = toHex(BigInt(SOLANA_MINT) & (2n ** 160n - 1n), {size: 32})
    const truncated: Terms = {...solanaVector, assets: [erc20Asset(truncatedMint, 1_000_000_000n)]}
    expect(digestTerms(truncated)).not.toBe(digestTerms(solanaVector))
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
