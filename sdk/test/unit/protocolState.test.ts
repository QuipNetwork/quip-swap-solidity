import {describe, expect, it} from 'vitest'
import {CrossChainLegState, SameChainState, sameChainWorkflowStage} from '../../src/protocol.js'

describe('explicit protocol state encodings', () => {
  it('matches the Solidity cross-chain enum order', () => {
    expect(CrossChainLegState.Unused).toBe(0)
    expect(CrossChainLegState.Committed).toBe(1)
    expect(CrossChainLegState.Claimed).toBe(2)
    expect(CrossChainLegState.Reclaimed).toBe(3)
  })

  it('distinguishes selected and partially executed same-chain outcomes', () => {
    expect(sameChainWorkflowStage(SameChainState.ClaimPending, 0)).toBe('claim-selected')
    expect(sameChainWorkflowStage(SameChainState.ClaimPending, 1)).toBe('claim-executing')
    expect(sameChainWorkflowStage(SameChainState.ReclaimPending, 0)).toBe('reclaim-selected')
    expect(sameChainWorkflowStage(SameChainState.ReclaimPending, 2)).toBe('reclaim-executing')
  })

  it('matches the Solidity same-chain enum order', () => {
    expect(SameChainState.Unused).toBe(0)
    expect(SameChainState.PartyCommitted).toBe(1)
    expect(SameChainState.BothCommitted).toBe(2)
    expect(SameChainState.ClaimPending).toBe(3)
    expect(SameChainState.ReclaimPending).toBe(4)
    expect(SameChainState.Claimed).toBe(5)
    expect(SameChainState.Reclaimed).toBe(6)
  })
})
