import {describe, expect, it} from 'vitest'
import {
  BASE_SEPOLIA_CHAIN_ID,
  BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY,
  OP_SEPOLIA_CHAIN_ID,
  OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY,
  PROTOTYPE_FINAL_CLAIM_DELAY,
} from '../../src/index.js'

describe('prototype timing policies', () => {
  it('exports both Base Sepolia and OP Sepolia party orderings', () => {
    expect(BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY.partyChainId).toBe(BASE_SEPOLIA_CHAIN_ID)
    expect(BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY.counterpartyChainId).toBe(OP_SEPOLIA_CHAIN_ID)
    expect(OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY.partyChainId).toBe(OP_SEPOLIA_CHAIN_ID)
    expect(OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY.counterpartyChainId).toBe(BASE_SEPOLIA_CHAIN_ID)
  })

  it('uses a symmetric 30-minute prototype safety bound without defining a claim wait', () => {
    expect(PROTOTYPE_FINAL_CLAIM_DELAY).toBe(1_800n)
    expect(BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY.partyToCounterpartyDelay).toBe(1_800n)
    expect(BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY.counterpartyToPartyDelay).toBe(1_800n)
  })
})
