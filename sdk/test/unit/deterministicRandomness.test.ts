import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {
  AuthorizationMode,
  DelegationPolicy,
  prepareTradeCommand,
  prepareTrustedCrossChainWorkflow,
  WrapperMode,
} from '../../src/index.js'
import type {ProtocolRandomness, SideTerms, TimingPolicy, WorkflowArgs} from '../../src/index.js'
import {AssetType} from '../../src/index.js'
import type {Hex32} from '../../src/index.js'

const ZERO = '0x0000000000000000000000000000000000000000' as Address
const ALICE = '0x1111111111111111111111111111111111111111' as Address
const BOB = '0x2222222222222222222222222222222222222222' as Address
const EXECUTOR = '0x3333333333333333333333333333333333333333' as Address
const VERIFIER = '0x4444444444444444444444444444444444444444' as Address
const WRAPPER = '0x5555555555555555555555555555555555555555' as Address
const h = (n: number) => `0x${n.toString(16).padStart(64, '0')}` as Hex32
const policy: TimingPolicy = {policyVersion: 1n, mode: WrapperMode.CrossChain, partyChainId: 31337n, counterpartyChainId: 31338n, partyToCounterpartyDelay: 10n, counterpartyToPartyDelay: 10n}
const side = (party: boolean): Omit<SideTerms, 'commitLock' | 'sideNonce'> => ({chainId: party ? 31337n : 31338n, assets: [{assetType: AssetType.Native, target: ZERO, id: 0n, amount: 1n}], principal: party ? ALICE : BOB, authorizationMode: AuthorizationMode.QuipWallet, principalKeyVersion: 0n, reclaimRecipient: party ? ALICE : BOB, recipient: party ? BOB : ALICE, commitmentDeadline: party ? 100n : 200n, claimDeadline: party ? 300n : 350n, reclaimRelease: 500n, delegationPolicy: party ? DelegationPolicy.NotAllowed : DelegationPolicy.Permissionless, delegate: ZERO, delegateKeyVersion: 0n})
const randomness: ProtocolRandomness = {settlementSecret: h(1), bobCommitSecret: h(2), partySideNonce: h(3), counterpartySideNonce: h(4), partyActionNonce: h(5), counterpartyActionNonce: h(6)}
const args = (injected?: ProtocolRandomness): WorkflowArgs => ({policy, partySide: side(true), counterpartySide: side(false), partyVerifier: VERIFIER, counterpartyVerifier: VERIFIER, partyWrapper: WRAPPER, counterpartyWrapper: WRAPPER, partyExpiry: 90n, counterpartyExpiry: 190n, requiredConfirmations: 3n, selectedBobSubmitter: EXECUTOR, ...(injected === undefined ? {} : {randomness: injected})})

describe('deterministic protocol randomness', () => {
  it('binds every named value to its exact protocol role and replays identically', () => {
    const first = prepareTrustedCrossChainWorkflow(args(randomness))
    const second = prepareTrustedCrossChainWorkflow(args(randomness))
    expect(first.workflow.tradeId).toBe(second.workflow.tradeId)
    expect(first.workflow.lock).toBe(second.workflow.lock)
    expect(first.settlementSecret).toBe(randomness.settlementSecret)
    expect(first.bobCommitSecret).toBe(randomness.bobCommitSecret)
    expect(first.workflow.terms.partySide.sideNonce).toBe(randomness.partySideNonce)
    expect(first.workflow.terms.counterpartySide.sideNonce).toBe(randomness.counterpartySideNonce)
    expect(first.workflow.partyAuthorization.payload.actionNonce).toBe(randomness.partyActionNonce)
    expect(first.workflow.counterpartyAuthorization.payload.actionNonce).toBe(randomness.counterpartyActionNonce)
  })

  it('rejects zero, duplicate, mixed-source, and non-demo injection', () => {
    expect(() => prepareTrustedCrossChainWorkflow(args({...randomness, partySideNonce: h(0)}))).toThrow('nonzero')
    expect(() => prepareTrustedCrossChainWorkflow(args({...randomness, partySideNonce: randomness.counterpartySideNonce}))).toThrow('independent')
    expect(() => prepareTrustedCrossChainWorkflow({...args(randomness), randomHex32: () => h(9)})).toThrow('not both')
    expect(() => prepareTradeCommand({workflow: args(randomness), finalClaimExecutors: [EXECUTOR]})).toThrow('unsafe-demo')
  })

  it('uses fresh independent randomness by default', () => {
    const first = prepareTrustedCrossChainWorkflow(args())
    const second = prepareTrustedCrossChainWorkflow(args())
    expect(first.workflow.tradeId).not.toBe(second.workflow.tradeId)
    expect(first.workflow.lock).not.toBe(second.workflow.lock)
    expect(first.settlementSecret).not.toBe(first.bobCommitSecret)
  })
})
