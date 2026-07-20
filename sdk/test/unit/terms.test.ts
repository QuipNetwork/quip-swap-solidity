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
import {describe, expect, it} from 'vitest'
import {erc1155Asset, erc20Asset, erc721Asset, nativeAsset} from '../../src/assets.js'
import {SOLANA_MAINNET_CHAIN_ID, U64_MAX} from '../../src/chains.js'
import {QuipSwapError} from '../../src/errors.js'
import {assertEvmLocalLeg, createTerms, proposedBy, validateTermPairing, validateTerms} from '../../src/terms.js'
import {AssetType} from '../../src/types.js'
import {ZERO_BYTES32} from '../../src/universalAddress.js'
import type {Asset} from '../../src/types.js'
import {
  ALICE,
  aliceTerms,
  BOB,
  bobTerms,
  CHAIN_A,
  SOLANA_MINT,
  SOLANA_PUBKEY,
  withOptimistic,
  withOverrides,
} from '../helpers/fixtures.js'

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

  it('rejects zero reclaimRecipient (contract: ZeroRecipient)', () => {
    expect(codeOf(() => validateTerms(withOverrides(valid, {reclaimRecipient: ZERO_BYTES32})))).toBe(
      'ZERO_RECIPIENT',
    )
  })

  it('rejects zero recipient (contract: ZeroRecipient)', () => {
    expect(codeOf(() => validateTerms(withOverrides(valid, {recipient: ZERO_BYTES32})))).toBe('ZERO_RECIPIENT')
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
    const bad: Asset = {assetType: AssetType.ERC20, target: ZERO_BYTES32, id: 0n, amount: 1n}
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

  it('defaults optimistic to false when omitted, and freezes an explicit true in', () => {
    const args = {
      chainId: CHAIN_A,
      reclaimRecipient: ALICE,
      recipient: BOB,
      commitmentDeadline: 100n,
      claimDeadline: 200n,
      reclaimRelease: 300n,
      assets: [nativeAsset(1n)],
    }
    expect(createTerms(args).optimistic).toBe(false)
    expect(createTerms({...args, optimistic: true}).optimistic).toBe(true)
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

  it('accepts both sides optimistic (bilateral opt-in)', () => {
    expect(() => validateTermPairing(withOptimistic(alice), withOptimistic(bob))).not.toThrow()
  })

  it('rejects mismatched optimistic flags in both directions (contract: OptimismMismatch)', () => {
    expect(codeOf(() => validateTermPairing(withOptimistic(alice), bob))).toBe('OPTIMISM_MISMATCH')
    expect(codeOf(() => validateTermPairing(alice, withOptimistic(bob)))).toBe('OPTIMISM_MISMATCH')
  })

  it('checks interleaving BEFORE the optimistic flags — disordered-and-both-optimistic reports the ordering', () => {
    const sequentialA = withOverrides(withOptimistic(alice), {
      commitmentDeadline: 100n,
      claimDeadline: 200n,
      reclaimRelease: 300n,
    })
    const sequentialB = withOverrides(withOptimistic(bob), {
      commitmentDeadline: 400n,
      claimDeadline: 500n,
      reclaimRelease: 600n,
    })
    expect(codeOf(() => validateTermPairing(sequentialA, sequentialB))).toBe('DISORDERED_DEADLINES')
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

describe('validateTerms (SVM legs)', () => {
  // an SVM leg mirroring the Solidity fixture: Solana chain id, foreign mint
  // + reclaimRecipient (dereferenced only on Solana), EVM-narrowable recipient
  const svmLeg = withOverrides(aliceTerms(SOLANA_MAINNET_CHAIN_ID), {
    reclaimRecipient: SOLANA_PUBKEY,
    assets: [erc20Asset(SOLANA_MINT, 1_000_000_000n)],
  })

  it('accepts a Solana-styled fungible leg', () => {
    expect(() => validateTerms(svmLeg)).not.toThrow()
  })

  it('accepts a vanilla NFT leg (mint IS the identity: id 0, amount 1)', () => {
    const nft = withOverrides(svmLeg, {assets: [erc721Asset(SOLANA_MINT, 0n)]})
    expect(() => validateTerms(nft)).not.toThrow()
  })

  it('rejects ERC-1155-semantics assets (no (contract, id) dimension on Solana)', () => {
    const bad = withOverrides(svmLeg, {assets: [erc1155Asset(SOLANA_MINT, 1n, 5n)]})
    expect(codeOf(() => validateTerms(bad))).toBe('UNSUPPORTED_SVM_ASSET')
  })

  it('rejects NFT legs with a non-zero id (the mint is the identity)', () => {
    const bad = withOverrides(svmLeg, {assets: [erc721Asset(SOLANA_MINT, 7n)]})
    expect(codeOf(() => validateTerms(bad))).toBe('UNSUPPORTED_SVM_ASSET')
  })

  it('rejects amounts above u64 max (SPL amounts are u64)', () => {
    const bad = withOverrides(svmLeg, {assets: [erc20Asset(SOLANA_MINT, U64_MAX + 1n)]})
    expect(codeOf(() => validateTerms(bad))).toBe('AMOUNT_EXCEEDS_U64')
    const ok = withOverrides(svmLeg, {assets: [erc20Asset(SOLANA_MINT, U64_MAX)]})
    expect(() => validateTerms(ok)).not.toThrow()
  })

  it('applies no u64 bound to EVM legs', () => {
    const evmLeg = withOverrides(aliceTerms(CHAIN_A), {assets: [nativeAsset(U64_MAX + 1n)]})
    expect(() => validateTerms(evmLeg)).not.toThrow()
  })
})

describe('assertEvmLocalLeg (commit preflight)', () => {
  // cross-chain pairing: Alice's leg local (EVM), Bob's leg on Solana with a
  // foreign mint/reclaimRecipient and an EVM recipient (paid on THIS chain)
  const localLeg = aliceTerms(CHAIN_A)
  const solanaLeg = withOverrides(bobTerms(SOLANA_MAINNET_CHAIN_ID), {
    reclaimRecipient: SOLANA_PUBKEY,
    assets: [erc20Asset(SOLANA_MINT, 1_000_000_000n)],
  })

  it('accepts the canonical cross-chain pairing', () => {
    expect(() => assertEvmLocalLeg(localLeg, solanaLeg)).not.toThrow()
  })

  it('accepts a foreign recipient on the LOCAL leg (it receives on the Solana side)', () => {
    const local = withOverrides(localLeg, {recipient: SOLANA_PUBKEY})
    expect(() => assertEvmLocalLeg(local, solanaLeg)).not.toThrow()
  })

  it('rejects a foreign reclaimRecipient on the local leg (refunds pay out here)', () => {
    const bad = withOverrides(localLeg, {reclaimRecipient: SOLANA_PUBKEY})
    expect(codeOf(() => assertEvmLocalLeg(bad, solanaLeg))).toBe('NOT_EVM_ADDRESS')
  })

  it('rejects a foreign asset target on the local leg (escrow pulls here)', () => {
    const bad = withOverrides(localLeg, {assets: [erc20Asset(SOLANA_MINT, 5n)]})
    expect(codeOf(() => assertEvmLocalLeg(bad, solanaLeg))).toBe('NOT_EVM_ADDRESS')
  })

  it("rejects a foreign counterparty recipient (the local escrow's claim pays it here)", () => {
    const bad = withOverrides(solanaLeg, {recipient: SOLANA_PUBKEY})
    expect(codeOf(() => assertEvmLocalLeg(localLeg, bad))).toBe('NOT_EVM_ADDRESS')
  })

  it('same-chain early catch: a foreign party recipient is rejected before funds lock', () => {
    // the contract defers this to the counterparty's own commit; the SDK
    // fails fast so a doomed same-chain pairing never escrows anything
    const bad = withOverrides(localLeg, {recipient: SOLANA_PUBKEY})
    expect(codeOf(() => assertEvmLocalLeg(bad, bobTerms(CHAIN_A)))).toBe('NOT_EVM_ADDRESS')
  })
})
