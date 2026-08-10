import {describe, expect, test} from 'vitest'
import {
  AuthorizationMode, DelegationPolicy, deriveCommitLock, gateContextId, validateCommitProgression,
} from '../../src/protocol.js'
import type {ProtocolTerms, SideTerms} from '../../src/protocol.js'
import {AssetType} from '../../src/types.js'
import type {Hex32} from '../../src/types.js'

const ZERO = `0x${'00'.repeat(32)}` as Hex32
const SECRET = `0x${'11'.repeat(32)}` as Hex32
const WRONG = `0x${'22'.repeat(32)}` as Hex32
const side = (chainId: bigint, principal: `0x${string}`, nonce: Hex32): SideTerms => ({
  chainId, assets: [{assetType: AssetType.Native, target: '0x0000000000000000000000000000000000000000', id: 0n, amount: 1n}],
  principal, authorizationMode: AuthorizationMode.RegisteredDirect, principalKeyVersion: 1n,
  reclaimRecipient: principal, recipient: principal, commitmentDeadline: 10n, claimDeadline: 20n,
  reclaimRelease: 30n, commitLock: ZERO, delegationPolicy: DelegationPolicy.NotAllowed,
  delegate: '0x0000000000000000000000000000000000000000', delegateKeyVersion: 0n, sideNonce: nonce,
})
const crossTerms = (): ProtocolTerms => {
  const terms: ProtocolTerms = {
    timingPolicyId: `0x${'33'.repeat(32)}`,
    partySide: side(1n, '0x00000000000000000000000000000000000000a1', `0x${'44'.repeat(32)}`),
    counterpartySide: side(2n, '0x00000000000000000000000000000000000000b2', `0x${'55'.repeat(32)}`),
  }
  return {...terms, counterpartySide: {...terms.counterpartySide,
    commitLock: deriveCommitLock(gateContextId(terms), SECRET)}}
}

describe('mandatory Bob commit progression', () => {
  test('accepts zero only for the cross-chain party commit and exact preimage for counterparty', () => {
    const terms = crossTerms()
    expect(() => validateCommitProgression(terms, true, ZERO)).not.toThrow()
    expect(() => validateCommitProgression(terms, false, SECRET)).not.toThrow()
  })
  test('rejects missing, wrong, and premature secrets', () => {
    const terms = crossTerms()
    expect(() => validateCommitProgression(terms, false, ZERO)).toThrow('Missing')
    expect(() => validateCommitProgression(terms, false, WRONG)).toThrow('Invalid Bob')
    expect(() => validateCommitProgression(terms, true, SECRET)).toThrow('Unexpected')
  })
  test('same-chain commits require the canonical zero secret', () => {
    const terms = crossTerms()
    const same = {...terms, counterpartySide: {...terms.counterpartySide, chainId: 1n, commitLock: ZERO}}
    expect(() => validateCommitProgression(same, false, ZERO)).not.toThrow()
    expect(() => validateCommitProgression(same, false, SECRET)).toThrow('Unexpected')
  })
})
