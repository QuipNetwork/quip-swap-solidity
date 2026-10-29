/**
 * Terms structural-validation and pairing unit tests.
 *
 * Covers: every `validateTerms` rejection (mirroring
 * `TermsLib.validateTerms`), the deliberate ABSENCE of a deadline-freshness
 * check, pairing interleaving in both directions, equal-timestamp
 * rejection, `proposedBy`, and `createTerms` immutability.
 *
 * Parallels `test/TermsLib/behaviors/validateTerms.t.sol` and
 * `test/TermsLib/behaviors/validateTermPairing.t.sol`.
 */
import {zeroAddress} from 'viem'
import {describe, expect, it} from 'vitest'
import {nativeAsset} from '../../src/assets.js'
import {QuipSwapError} from '../../src/errors.js'
import {createTerms, proposedBy, validateTermPairing, validateTerms} from '../../src/terms.js'
import {AssetType} from '../../src/types.js'
import type {Asset} from '../../src/types.js'
import {ALICE, aliceTerms, BOB, bobTerms, CHAIN_A, withOverrides} from '../helpers/fixtures.js'

function codeOf(fn: () => unknown): string {
  try {
    fn()
  } catch (error) {
    if (error instanceof QuipSwapError) return error.code
    throw error
  }
  throw new Error('expected the call to throw a QuipSwapError')
}

const valid = aliceTerms(CHAIN_A)

describe('validateTerms', () => {
  it('accepts the canonical fixture', () => {
    expect(() => validateTerms(valid)).not.toThrow()
  })

  it('rejects zero chain id (contract: ZeroChainId)', () => {
    expect(codeOf(() => validateTerms(withOverrides(valid, {chainId: 0n})))).toBe('ZERO_CHAIN_ID')
  })

  it('rejects zero reclaimRecipient (contract: ZeroAddressRecipient)', () => {
    expect(codeOf(() => validateTerms(withOverrides(valid, {reclaimRecipient: zeroAddress})))).toBe(
      'ZERO_ADDRESS_RECIPIENT',
    )
  })

  it('rejects zero recipient (contract: ZeroAddressRecipient)', () => {
    expect(codeOf(() => validateTerms(withOverrides(valid, {recipient: zeroAddress})))).toBe('ZERO_ADDRESS_RECIPIENT')
  })

  it('rejects zero commitmentDeadline (contract: ZeroDeadline)', () => {
    expect(codeOf(() => validateTerms(withOverrides(valid, {commitmentDeadline: 0n})))).toBe('ZERO_DEADLINE')
  })

  it('rejects equal timestamps anywhere — strict ordering only (contract: DisordedDeadlines)', () => {
    expect(
      codeOf(() => validateTerms(withOverrides(valid, {claimDeadline: valid.commitmentDeadline}))),
    ).toBe('DISORDERED_DEADLINES')
    expect(codeOf(() => validateTerms(withOverrides(valid, {reclaimRelease: valid.claimDeadline})))).toBe(
      'DISORDERED_DEADLINES',
    )
  })

  it('rejects commitmentDeadline >= claimDeadline', () => {
    expect(
      codeOf(() => validateTerms(withOverrides(valid, {commitmentDeadline: valid.claimDeadline + 1n}))),
    ).toBe('DISORDERED_DEADLINES')
  })

  it('rejects claimDeadline >= reclaimRelease', () => {
    expect(
      codeOf(() => validateTerms(withOverrides(valid, {claimDeadline: valid.reclaimRelease + 1n}))),
    ).toBe('DISORDERED_DEADLINES')
  })

  it('rejects empty assets (contract: EmptyAssets)', () => {
    expect(codeOf(() => validateTerms(withOverrides(valid, {assets: []})))).toBe('EMPTY_ASSETS')
  })

  it('rejects invalid nested assets', () => {
    const bad: Asset = {assetType: AssetType.ERC20, target: zeroAddress, id: 0n, amount: 1n}
    expect(codeOf(() => validateTerms(withOverrides(valid, {assets: [nativeAsset(1n), bad]})))).toBe(
      'INVALID_ERC20_ASSET',
    )
  })

  it('does NOT reject elapsed deadlines — freshness is per-action window, not structure', () => {
    // the taker commits AFTER the proposer's commitmentDeadline has elapsed;
    // commit validates BOTH sides, so a freshness check here would break the
    // taker's commit (see TermsLib.validateTerms comments)
    const elapsed = withOverrides(valid, {commitmentDeadline: 1n, claimDeadline: 2n, reclaimRelease: 3n})
    expect(() => validateTerms(elapsed)).not.toThrow()
  })
})

describe('createTerms', () => {
  it('returns a frozen object with a defensively copied, frozen asset array', () => {
    const assets = [nativeAsset(1n)]
    const terms = createTerms({
      chainId: CHAIN_A,
      reclaimRecipient: ALICE,
      recipient: BOB,
      commitmentDeadline: 100n,
      claimDeadline: 200n,
      reclaimRelease: 300n,
      assets,
    })
    expect(Object.isFrozen(terms)).toBe(true)
    expect(Object.isFrozen(terms.assets)).toBe(true)
    // mutating the caller's array must not affect the created terms
    assets.push(nativeAsset(2n))
    expect(terms.assets).toHaveLength(1)
  })

  it('validates on construction', () => {
    expect(
      codeOf(() =>
        createTerms({
          chainId: 0n,
          reclaimRecipient: ALICE,
          recipient: BOB,
          commitmentDeadline: 100n,
          claimDeadline: 200n,
          reclaimRelease: 300n,
          assets: [nativeAsset(1n)],
        }),
      ),
    ).toBe('ZERO_CHAIN_ID')
  })
})

describe('validateTermPairing', () => {
  const alice = aliceTerms(CHAIN_A)
  const bob = bobTerms(CHAIN_A)

  it('accepts a valid interleaving with A proposing, in both argument orders', () => {
    expect(() => validateTermPairing(alice, bob)).not.toThrow()
    expect(() => validateTermPairing(bob, alice)).not.toThrow()
  })

  it('accepts a valid interleaving with B proposing', () => {
    // give "B" the earlier schedule: swap the lifecycle timestamps
    const aLate = withOverrides(alice, {
      commitmentDeadline: bob.commitmentDeadline,
      claimDeadline: bob.claimDeadline,
      reclaimRelease: bob.reclaimRelease,
    })
    const bEarly = withOverrides(bob, {
      commitmentDeadline: alice.commitmentDeadline,
      claimDeadline: alice.claimDeadline,
      reclaimRelease: alice.reclaimRelease,
    })
    expect(() => validateTermPairing(aLate, bEarly)).not.toThrow()
  })

  it('rejects non-interleaved schedules (contract: DisordedDeadlines)', () => {
    // sequential, not interleaved: all of A's timestamps before all of B's
    const sequentialA = withOverrides(alice, {commitmentDeadline: 100n, claimDeadline: 200n, reclaimRelease: 300n})
    const sequentialB = withOverrides(bob, {commitmentDeadline: 400n, claimDeadline: 500n, reclaimRelease: 600n})
    expect(codeOf(() => validateTermPairing(sequentialA, sequentialB))).toBe('DISORDERED_DEADLINES')
  })

  it('rejects equal timestamps across sides', () => {
    const sameCommit = withOverrides(bob, {commitmentDeadline: alice.commitmentDeadline})
    expect(codeOf(() => validateTermPairing(alice, sameCommit))).toBe('DISORDERED_DEADLINES')
  })
})

describe('proposedBy', () => {
  const alice = aliceTerms(CHAIN_A)
  const bob = bobTerms(CHAIN_A)

  it('identifies the side with the smaller commitmentDeadline as proposer', () => {
    expect(proposedBy(alice, bob)).toBe('party')
    expect(proposedBy(bob, alice)).toBe('counterparty')
  })
})
