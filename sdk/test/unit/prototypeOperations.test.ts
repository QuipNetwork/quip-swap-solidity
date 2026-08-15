import {describe, expect, it} from 'vitest'
import {
  BASE_SEPOLIA_CHAIN_ID,
  OP_SEPOLIA_CHAIN_ID,
  PROTOTYPE_OPERATING_PROFILE,
  PROTOTYPE_RETRY_POLICY,
  prototypeConfirmations,
  submitWithFeeBumps,
} from '../../src/index.js'

describe('prototype operating profile', () => {
  it('requires 12 confirmations and two RPC endpoints on both prototype chains', () => {
    expect(prototypeConfirmations(BASE_SEPOLIA_CHAIN_ID)).toBe(12n)
    expect(prototypeConfirmations(OP_SEPOLIA_CHAIN_ID)).toBe(12n)
    expect(PROTOTYPE_OPERATING_PROFILE.chains.every(chain => chain.rpcEndpointCount === 2)).toBe(true)
    expect(() => prototypeConfirmations(1n)).toThrow('unsupported prototype chain')
  })

  it('defines bounded monitoring and funded-executor requirements', () => {
    expect(PROTOTYPE_OPERATING_PROFILE.pollIntervalMs).toBe(2_000)
    expect(PROTOTYPE_OPERATING_PROFILE.staleHeadTimeoutMs).toBe(30_000)
    expect(PROTOTYPE_OPERATING_PROFILE.reclaimPollIntervalMs).toBe(15_000)
    expect(PROTOTYPE_OPERATING_PROFILE.executorMinimumBalanceWei).toBe(10n ** 16n)
    expect(PROTOTYPE_OPERATING_PROFILE.finalClaimExecutorCount).toBe(2)
  })

  it('retries three times with bounded 20-percent compounding fee multipliers', async () => {
    const observed: bigint[] = []
    await expect(submitWithFeeBumps(async multiplier => {
      observed.push(multiplier)
      if (observed.length < 3) throw new Error('not included')
      return 'included'
    }, PROTOTYPE_RETRY_POLICY)).resolves.toBe('included')
    expect(observed).toEqual([10_000n, 12_000n, 14_400n])
  })
})
