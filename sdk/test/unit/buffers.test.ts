/**
 * Schedule buffer (gap-SIZE) unit tests.
 *
 * Covers `checkScheduleBuffers`: passes when every adjacent gap meets the
 * minimum, throws `INSUFFICIENT_BUFFER` (with the offending-pair details)
 * when one is below, and returns the smallest adjacent gap. The default
 * constants are asserted to be the documented values.
 */
import {describe, expect, it} from 'vitest'
import {
  checkScheduleBuffers,
  DEFAULT_BUFFERS,
  DEFAULT_CROSS_CHAIN_BUFFER_SECONDS,
  DEFAULT_SAME_CHAIN_BUFFER_SECONDS,
} from '../../src/buffers.js'
import {QuipSwapError} from '../../src/errors.js'
import type {Terms} from '../../src/types.js'
import {aliceTerms, bobTerms, CHAIN_A, withOverrides} from '../helpers/fixtures.js'

/** A normalized proposer/taker pair with a uniform `gap` between every adjacent timestamp. */
function pairWithGap(
  gap: bigint): {
    proposer: Terms;
    taker: Terms
  } {
  const proposer = withOverrides(aliceTerms(CHAIN_A), {
    commitmentDeadline: gap,
    claimDeadline: 3n * gap,
    reclaimRelease: 5n * gap,
  })
  const taker = withOverrides(bobTerms(CHAIN_A), {
    commitmentDeadline: 2n * gap,
    claimDeadline: 4n * gap,
    reclaimRelease: 6n * gap,
  })

  return {
    proposer,
    taker
  }
}

describe('default buffer constants', () => {
  it('match the documented presets', () => {
    expect(DEFAULT_BUFFERS).toEqual({
      fastL2: 300n,
      standard: 1800n,
      conservativeL1: 3600n
    })
    expect(DEFAULT_CROSS_CHAIN_BUFFER_SECONDS).toBe(1800n)
    expect(DEFAULT_SAME_CHAIN_BUFFER_SECONDS).toBe(1800n)
  })
})

describe('checkScheduleBuffers', () => {
  it('passes when every adjacent gap meets the minimum and returns the smallest gap', () => {
    const {proposer, taker} = pairWithGap(1000n)

    expect(checkScheduleBuffers(proposer, taker, 1000n)).toEqual({
      minimumGapSeconds: 1000n
    })
    expect(checkScheduleBuffers(proposer, taker, 500n)).toEqual({
      minimumGapSeconds: 1000n
    })
  })

  it('throws INSUFFICIENT_BUFFER when a gap is below the minimum, with the offending pair in details', () => {
    const {proposer, taker} = pairWithGap(1000n)

    try {
      checkScheduleBuffers(proposer, taker, 1001n)
      expect.unreachable()
    }
    catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('INSUFFICIENT_BUFFER')
      // first adjacent pair is proposer.commit(1000) -> taker.commit(2000), gap 1000
      expect((error as QuipSwapError).details).toMatchObject({
        prevName: 'proposer.commitmentDeadline',
        nextName: 'taker.commitmentDeadline',
        gap: 1000n,
        minimumBufferSeconds: 1001n,
      })
    }
  })

  it('reports the SMALLEST adjacent gap when gaps are uneven (and flags it when too tight)', () => {
    // widen everything except the taker-claim → proposer-reclaim gap, which is 100
    const proposer = withOverrides(aliceTerms(CHAIN_A), {
      commitmentDeadline: 5000n,
      claimDeadline: 15000n,
      reclaimRelease: 20100n,
    })
    const taker = withOverrides(bobTerms(CHAIN_A), {
      commitmentDeadline: 10000n,
      claimDeadline: 20000n, // proposer.reclaim(20100) - taker.claim(20000) = 100 (smallest)
      reclaimRelease: 30000n,
    })

    expect(checkScheduleBuffers(proposer, taker, 100n)).toEqual({
      minimumGapSeconds: 100n
    })
    expect(() => checkScheduleBuffers(proposer, taker, 101n)).toThrow(QuipSwapError)
  })
})
