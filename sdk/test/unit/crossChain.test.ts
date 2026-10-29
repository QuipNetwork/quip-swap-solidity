/**
 * Cross-chain schedule validation unit tests.
 *
 * Covers: interleaving acceptance, the secret-holder-must-be-proposer rule
 * (the free-option guard — parallels `test/attack/CrossChainFreeOption.t.sol`),
 * reversed schedules, buffer sizing, and the reaction-buffer formula.
 */
import {describe, expect, it} from 'vitest'
import {QuipSwapError} from '../../src/errors.js'
import {validateCrossChainSchedule} from '../../src/workflows/crossChain.js'
import {
  ALICE_CLAIM_DEADLINE,
  ALICE_RECLAIM_RELEASE,
  aliceTerms,
  bobTerms,
  CHAIN_A,
  CHAIN_B,
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

// Alice = proposer + secret holder on Chain A; Bob = taker on Chain B.
// every adjacent gap in the canonical schedule is exactly 1000s
const alice = aliceTerms(CHAIN_A)
const bob = bobTerms(CHAIN_B)

describe('validateCrossChainSchedule', () => {
  it('accepts a correct interleaving with a sufficient buffer', () => {
    const schedule = validateCrossChainSchedule({
      proposerTerms: alice,
      takerTerms: bob,
      minimumBufferSeconds: 1000n,
    })
    expect(schedule.minimumGapSeconds).toBe(1000n)
  })

  it('applies DEFAULT_CROSS_CHAIN_BUFFER_SECONDS when minimumBufferSeconds is omitted', () => {
    // a wide schedule (2000s gaps) clears the default; omit the buffer arg
    const wideAlice = withOverrides(alice, {commitmentDeadline: 2000n, claimDeadline: 6000n, reclaimRelease: 10000n})
    const wideBob = withOverrides(bob, {commitmentDeadline: 4000n, claimDeadline: 8000n, reclaimRelease: 12000n})
    const schedule = validateCrossChainSchedule({proposerTerms: wideAlice, takerTerms: wideBob})
    expect(schedule.minimumGapSeconds).toBe(2000n)
  })

  it('the default buffer REJECTS the canonical 1000s schedule when omitted (default > 1000)', () => {
    // proves the default is actually enforced: DEFAULT_CROSS_CHAIN_BUFFER_SECONDS
    // (1800) exceeds the canonical 1000s gaps
    expect(codeOf(() => validateCrossChainSchedule({proposerTerms: alice, takerTerms: bob}))).toBe(
      'INSUFFICIENT_BUFFER',
    )
  })

  it('computes the reaction buffer as proposer.reclaimRelease - proposer.claimDeadline', () => {
    const schedule = validateCrossChainSchedule({
      proposerTerms: alice,
      takerTerms: bob,
      minimumBufferSeconds: 500n,
    })
    expect(schedule.reactionBufferSeconds).toBe(ALICE_RECLAIM_RELEASE - ALICE_CLAIM_DEADLINE)
  })

  it('rejects a secret holder that is not the proposer (the free-option guard)', () => {
    // pass the roles swapped: the "proposerTerms" (secret holder) has the
    // LATER schedule, which would let them claim the counterparty leg while
    // keeping the option to let their own leg expire
    expect(
      codeOf(() => validateCrossChainSchedule({proposerTerms: bob, takerTerms: alice, minimumBufferSeconds: 1n})),
    ).toBe('SECRET_HOLDER_NOT_PROPOSER')
  })

  it('rejects reversed (non-interleaved) schedules', () => {
    const sequentialAlice = withOverrides(alice, {commitmentDeadline: 100n, claimDeadline: 200n, reclaimRelease: 300n})
    const sequentialBob = withOverrides(bob, {commitmentDeadline: 400n, claimDeadline: 500n, reclaimRelease: 600n})
    expect(
      codeOf(() =>
        validateCrossChainSchedule({
          proposerTerms: sequentialAlice,
          takerTerms: sequentialBob,
          minimumBufferSeconds: 1n,
        }),
      ),
    ).toBe('DISORDERED_DEADLINES')
  })

  it('rejects an insufficient buffer on ANY adjacent gap', () => {
    expect(
      codeOf(() => validateCrossChainSchedule({proposerTerms: alice, takerTerms: bob, minimumBufferSeconds: 1001n})),
    ).toBe('INSUFFICIENT_BUFFER')
    // shrink only the reaction buffer (alice.claimDeadline -> alice.reclaimRelease 4500..5000 gap 500? adjust):
    const tightReaction = withOverrides(alice, {reclaimRelease: ALICE_CLAIM_DEADLINE + 500n})
    const adjustedBob = withOverrides(bob, {
      claimDeadline: ALICE_CLAIM_DEADLINE + 250n, // keep interleaving: alice.claim < bob.claim < alice.reclaim
      reclaimRelease: ALICE_CLAIM_DEADLINE + 750n,
    })
    expect(
      codeOf(() =>
        validateCrossChainSchedule({proposerTerms: tightReaction, takerTerms: adjustedBob, minimumBufferSeconds: 300n}),
      ),
    ).toBe('INSUFFICIENT_BUFFER')
  })

  it('accepts a sufficient buffer', () => {
    expect(() =>
      validateCrossChainSchedule({proposerTerms: alice, takerTerms: bob, minimumBufferSeconds: 999n}),
    ).not.toThrow()
  })

  it('rejects both legs on the same chain', () => {
    expect(
      codeOf(() =>
        validateCrossChainSchedule({
          proposerTerms: alice,
          takerTerms: bobTerms(CHAIN_A),
          minimumBufferSeconds: 1n,
        }),
      ),
    ).toBe('CHAIN_ID_MISMATCH')
  })

  // ---- clock skew: the reaction buffer must also absorb the chain pair's skew ----
  // canonical layout: gaps are 1000s each and the reaction buffer
  // (alice.reclaimRelease - alice.claimDeadline) spans two of them = 2000s.

  it('the default maxClockSkewSeconds of 0n adds no constraint', () => {
    // min=1000 clears every 1000s gap; with no skew the 2000s reaction buffer passes
    expect(() =>
      validateCrossChainSchedule({proposerTerms: alice, takerTerms: bob, minimumBufferSeconds: 1000n}),
    ).not.toThrow()
  })

  it('accepts when the reaction buffer exactly covers minimumBufferSeconds + maxClockSkewSeconds', () => {
    // required reaction = 1000 + 1000 = 2000; reaction buffer is exactly 2000 (boundary is inclusive).
    // the non-reaction 1000s gaps are NOT tightened by skew — only the reaction buffer carries it.
    expect(() =>
      validateCrossChainSchedule({
        proposerTerms: alice,
        takerTerms: bob,
        minimumBufferSeconds: 1000n,
        maxClockSkewSeconds: 1000n,
      }),
    ).not.toThrow()
  })

  it('rejects INSUFFICIENT_REACTION_BUFFER when the reaction buffer is below min + skew', () => {
    // required reaction = 1000 + 1001 = 2001 > the 2000s reaction buffer. Every adjacent gap
    // still clears min=1000, so this fails on the reaction constraint specifically, NOT INSUFFICIENT_BUFFER.
    expect(
      codeOf(() =>
        validateCrossChainSchedule({
          proposerTerms: alice,
          takerTerms: bob,
          minimumBufferSeconds: 1000n,
          maxClockSkewSeconds: 1001n,
        }),
      ),
    ).toBe('INSUFFICIENT_REACTION_BUFFER')
  })

  it('reports the required and actual reaction buffer in the error details', () => {
    let err: QuipSwapError | undefined
    try {
      validateCrossChainSchedule({
        proposerTerms: alice,
        takerTerms: bob,
        minimumBufferSeconds: 1000n,
        maxClockSkewSeconds: 1001n,
      })
    } catch (e) {
      if (e instanceof QuipSwapError) err = e
    }
    expect(err?.code).toBe('INSUFFICIENT_REACTION_BUFFER')
    expect(err?.details).toMatchObject({
      reactionBufferSeconds: ALICE_RECLAIM_RELEASE - ALICE_CLAIM_DEADLINE,
      requiredReactionBufferSeconds: 2001n,
      minimumBufferSeconds: 1000n,
      maxClockSkewSeconds: 1001n,
    })
  })
})
