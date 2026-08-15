import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {
  AuthorizationMode,
  CLIENT_STATE_SCHEMA,
  DelegationPolicy,
  TrustedCrossChainWorkflow,
  clientStatesEqual,
  parseClientState,
  persistProtocolTerms,
  serializeClientState,
} from '../../src/index.js'
import type {AliceClientState, BobClientState, SideTerms, TimingPolicy} from '../../src/index.js'
import {AssetType, WrapperMode} from '../../src/index.js'
import type {Hex32} from '../../src/index.js'

const ZERO = '0x0000000000000000000000000000000000000000' as Address
const ALICE = '0x1111111111111111111111111111111111111111' as Address
const BOB = '0x2222222222222222222222222222222222222222' as Address
const EXECUTOR = '0x3333333333333333333333333333333333333333' as Address
const VERIFIER = '0x4444444444444444444444444444444444444444' as Address
const WRAPPER = '0x5555555555555555555555555555555555555555' as Address
const H = (byte: string) => `0x${byte.repeat(64)}` as Hex32
const policy: TimingPolicy = {policyVersion: 1n, mode: WrapperMode.CrossChain, partyChainId: 31337n, counterpartyChainId: 31338n, partyToCounterpartyDelay: 10n, counterpartyToPartyDelay: 10n}
const side = (party: boolean): Omit<SideTerms, 'commitLock' | 'sideNonce'> => ({
  chainId: party ? 31337n : 31338n,
  assets: [{assetType: AssetType.Native, target: ZERO, id: 0n, amount: 1n}],
  principal: party ? ALICE : BOB,
  authorizationMode: AuthorizationMode.QuipWallet,
  principalKeyVersion: 0n,
  reclaimRecipient: party ? ALICE : BOB,
  recipient: party ? BOB : ALICE,
  commitmentDeadline: party ? 100n : 200n,
  claimDeadline: party ? 300n : 350n,
  reclaimRelease: 500n,
  delegationPolicy: party ? DelegationPolicy.NotAllowed : DelegationPolicy.Permissionless,
  delegate: ZERO,
  delegateKeyVersion: 0n,
})
function flow(): TrustedCrossChainWorkflow {
  let n = 1
  return new TrustedCrossChainWorkflow({policy, partySide: side(true), counterpartySide: side(false), partyVerifier: VERIFIER, counterpartyVerifier: VERIFIER, partyWrapper: WRAPPER, counterpartyWrapper: WRAPPER, partyExpiry: 90n, counterpartyExpiry: 190n, requiredConfirmations: 3n, selectedBobSubmitter: EXECUTOR, randomHex32: () => `0x${(n++).toString(16).padStart(64, '0')}` as Hex32})
}
function common() {
  const workflow = flow()
  return {
    schema: CLIENT_STATE_SCHEMA,
    generation: 1,
    sequence: 0,
    tradeId: workflow.tradeId,
    terms: persistProtocolTerms(workflow.terms),
    derived: {gateContextId: H('a'), settlementLock: workflow.lock, partyCommitPayloadHash: workflow.partyAuthorization.payloadHash, counterpartyCommitPayloadHash: workflow.counterpartyAuthorization.payloadHash},
    selected: {bobSubmitter: EXECUTOR, finalClaimExecutors: [EXECUTOR]},
    stage: 'prepared' as const,
    aliceCommit: {status: 'not-submitted' as const},
    recovery: {active: false},
  }
}

describe('party client state persistence', () => {
  it('round-trips Alice and Bob independently with decimal bigint fields', () => {
    const alice: AliceClientState = {...common(), party: 'alice', progression: {released: false}}
    const bob: BobClientState = {...common(), party: 'bob', progression: {received: false}}
    for (const state of [alice, bob]) {
      const restored = parseClientState(serializeClientState(state))
      expect(restored).toEqual(state)
      expect(clientStatesEqual(restored, state)).toBe(true)
      expect(restored.terms.partySide.chainId).toBe('31337')
    }
    expect(clientStatesEqual(alice, bob)).toBe(false)
  })

  it('rejects malformed schemas and mixed party progression state', () => {
    const alice: AliceClientState = {...common(), party: 'alice', progression: {released: false}}
    expect(() => parseClientState('{')).toThrow('not valid JSON')
    expect(() => parseClientState(JSON.stringify({...alice, schema: 'old'}))).toThrow('unsupported')
    expect(() => parseClientState(JSON.stringify({...alice, progression: {received: false}}))).toThrow('Alice progression')
  })

  it('contains observations and decisions but no secret fields', () => {
    const alice: AliceClientState = {...common(), party: 'alice', progression: {released: false}}
    const serialized = serializeClientState(alice)
    expect(serialized).toContain('finalClaimExecutors')
    expect(serialized).toContain('aliceCommit')
    expect(serialized).not.toMatch(/bobCommitSecret|"secret"/i)
  })
})
