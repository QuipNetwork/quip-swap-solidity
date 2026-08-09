import {describe, expect, it} from 'vitest'
import {CrossChainLegState, SameChainState} from '../../src/protocol.js'

describe('explicit protocol state encodings', () => {
  it('matches the Solidity cross-chain enum order', () => {
    expect(CrossChainLegState.Unused).toBe(0)
    expect(CrossChainLegState.Committed).toBe(1)
    expect(CrossChainLegState.Claimed).toBe(2)
    expect(CrossChainLegState.Reclaimed).toBe(3)
  })

  it('matches the Solidity same-chain enum order', () => {
    expect(SameChainState.Unused).toBe(0)
    expect(SameChainState.PartyCommitted).toBe(1)
    expect(SameChainState.BothCommitted).toBe(2)
    expect(SameChainState.Claimed).toBe(3)
    expect(SameChainState.Reclaimed).toBe(4)
  })
})
