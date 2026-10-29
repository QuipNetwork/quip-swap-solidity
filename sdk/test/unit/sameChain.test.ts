/**
 * Same-chain planning unit tests — focused on the NEW buffer (gap-SIZE)
 * protection added to `planSameChainSwap`.
 *
 * Regression this closes: a same-chain swap with dangerously tight windows
 * used to pass `planSameChainSwap` (it only checked order/chain). Now the
 * gap-size buffer is enforced, defaulting to
 * `DEFAULT_SAME_CHAIN_BUFFER_SECONDS` and overrideable.
 */
import {describe, expect, it} from 'vitest'
import {DEFAULT_SAME_CHAIN_BUFFER_SECONDS} from '../../src/buffers.js'
import {QuipSwapError} from '../../src/errors.js'
import {planSameChainSwap} from '../../src/workflows/sameChain.js'
import type {Terms} from '../../src/types.js'
import {aliceTerms, bobTerms, CHAIN_A, withOverrides} from '../helpers/fixtures.js'

function codeOf(fn: () => unknown): string {
  try {
    fn()
  } catch (error) {
    if (error instanceof QuipSwapError) return error.code
    throw error
  }
  throw new Error('expected the call to throw a QuipSwapError')
}

/** A same-chain proposer/taker pair (both on CHAIN_A) with a uniform `gap`. */
function sameChainPair(gap: bigint): {a: Terms; b: Terms} {
  const a = withOverrides(aliceTerms(CHAIN_A), {
    commitmentDeadline: gap,
    claimDeadline: 3n * gap,
    reclaimRelease: 5n * gap,
  })
  const b = withOverrides(bobTerms(CHAIN_A), {
    commitmentDeadline: 2n * gap,
    claimDeadline: 4n * gap,
    reclaimRelease: 6n * gap,
  })
  return {a, b}
}

describe('planSameChainSwap buffer enforcement', () => {
  it('REGRESSION: 1-second windows now throw INSUFFICIENT_BUFFER (previously passed)', () => {
    const {a, b} = sameChainPair(1n)
    expect(codeOf(() => planSameChainSwap(a, b))).toBe('INSUFFICIENT_BUFFER')
  })

  it('omitting opts applies DEFAULT_SAME_CHAIN_BUFFER_SECONDS — the canonical 1000s schedule is rejected', () => {
    // default (1800) > 1000s gaps → rejected, proving the default is enforced
    expect(DEFAULT_SAME_CHAIN_BUFFER_SECONDS).toBe(1800n)
    const {a, b} = sameChainPair(1000n)
    expect(codeOf(() => planSameChainSwap(a, b))).toBe('INSUFFICIENT_BUFFER')
  })

  it('a comfortably-spaced schedule (gaps ≥ default) passes with no opts and normalizes roles', () => {
    const {a, b} = sameChainPair(2000n)
    const plan = planSameChainSwap(a, b)
    expect(plan.proposerTerms).toBe(a) // smaller commitmentDeadline
    expect(plan.takerTerms).toBe(b)
    expect(BigInt(plan.canonicalDigest)).not.toBe(0n)
  })

  it('an explicit override below the schedule gaps still throws at the override value', () => {
    const {a, b} = sameChainPair(2000n) // gaps 2000 — fine under the default
    expect(codeOf(() => planSameChainSwap(a, b, {minimumBufferSeconds: 2001n}))).toBe('INSUFFICIENT_BUFFER')
  })

  it('an explicit override BELOW the default lets a tighter (but ordered) schedule through', () => {
    const {a, b} = sameChainPair(1000n) // rejected by the default, allowed at 1000n
    expect(() => planSameChainSwap(a, b, {minimumBufferSeconds: 1000n})).not.toThrow()
  })
})
