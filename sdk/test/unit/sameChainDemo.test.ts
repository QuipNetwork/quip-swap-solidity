import {getAddress} from 'viem'
import type {Hex} from 'viem'
import {describe, expect, it} from 'vitest'
import {WrapperMode, settlementLock, tradeId, validateCommitProgression, validateProtocolTerms, wrapperMode} from '../../src/index.js'
import {
  SAME_CHAIN_DEMO_CHAIN_ID,
  buildSameChainDemoTerms,
  sameChainDemoPolicy,
} from '../../scripts/same-chain-demo.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)
const ZERO32 = ('0x' + '00'.repeat(32)) as Hex

function terms() {
  return buildSameChainDemoTerms({
    chainId: BigInt(SAME_CHAIN_DEMO_CHAIN_ID),
    alice: address('1'),
    bob: address('2'),
    aliceToken: address('3'),
    bobToken: address('4'),
    now: 4_000_000_000n,
  })
}

describe('current-protocol same-chain demo foundation', () => {
  it('builds canonical independent same-chain terms', () => {
    const value = terms()
    const policy = sameChainDemoPolicy(BigInt(SAME_CHAIN_DEMO_CHAIN_ID))
    expect(() => validateProtocolTerms(value, policy)).not.toThrow()
    expect(wrapperMode(value)).toBe(WrapperMode.SameChain)
    expect(value.partySide.chainId).toBe(value.counterpartySide.chainId)
    expect(value.partySide.commitLock).toBe(ZERO32)
    expect(value.counterpartySide.commitLock).toBe(ZERO32)
    expect(value.partySide.sideNonce).not.toBe(value.counterpartySide.sideNonce)
    expect(value.partySide.principal).not.toBe(value.counterpartySide.principal)
    expect(() => validateCommitProgression(value, true, ZERO32)).not.toThrow()
    expect(() => validateCommitProgression(value, false, ZERO32)).not.toThrow()
  })

  it('binds the settlement lock to the complete terms and secret', () => {
    const value = terms()
    const secret = `0x${'00'.repeat(31)}01` as const
    const id = tradeId(value)
    expect(settlementLock(id, secret)).not.toBe(ZERO32)
    expect(tradeId({...value, partySide: {...value.partySide, sideNonce: `0x${'00'.repeat(31)}09`}})).not.toBe(id)
  })
})
