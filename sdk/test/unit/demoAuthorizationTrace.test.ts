import type {Address, Hex} from 'viem'
import {describe, expect, it} from 'vitest'
import {
  AUTHORIZATION_TRACE_SCHEMA,
  AuthorizationTraceRecorder,
  serializeAuthorizationTrace,
} from '../../scripts/demo/shared/authorization-trace.js'
import {AssetType, AuthorizationMode, DelegationPolicy, TrustedCrossChainWorkflow, WrapperMode} from '../../src/index.js'
import type {Hex32, SideTerms, TimingPolicy} from '../../src/index.js'

const address = (digit: string) => `0x${digit.repeat(40)}` as Address
const ZERO = address('0')
const ALICE = address('1')
const BOB = address('2')
const WALLET = address('3')
const GATEWAY = address('4')
const VERIFIER = address('5')
const ALICE_TX = `0x${'aa'.repeat(32)}` as Hex
const policy: TimingPolicy = {policyVersion: 1n, mode: WrapperMode.CrossChain, partyChainId: 31337n, counterpartyChainId: 31338n, partyToCounterpartyDelay: 10n, counterpartyToPartyDelay: 10n}
const side = (party: boolean): Omit<SideTerms, 'commitLock' | 'sideNonce'> => ({
  chainId: party ? 31337n : 31338n,
  assets: [{assetType: AssetType.Native, target: ZERO, id: 0n, amount: 1n}],
  principal: party ? ALICE : BOB,
  authorizationMode: party ? AuthorizationMode.QuipWallet : AuthorizationMode.RegisteredDirect,
  principalKeyVersion: party ? 0n : 1n,
  reclaimRecipient: party ? ALICE : BOB,
  recipient: party ? BOB : ALICE,
  commitmentDeadline: party ? 100n : 200n,
  claimDeadline: party ? 300n : 350n,
  reclaimRelease: 500n,
  delegationPolicy: DelegationPolicy.NotAllowed,
  delegate: ZERO,
  delegateKeyVersion: 0n,
})

function workflow(): TrustedCrossChainWorkflow {
  let n = 1
  return new TrustedCrossChainWorkflow({
    policy,
    partySide: side(true),
    counterpartySide: side(false),
    partyVerifier: WALLET,
    counterpartyVerifier: GATEWAY,
    partyWrapper: address('6'),
    counterpartyWrapper: address('7'),
    partyExpiry: 90n,
    counterpartyExpiry: 190n,
    requiredConfirmations: 3n,
    selectedBobSubmitter: BOB,
    randomHex32: () => `0x${(n++).toString(16).padStart(64, '0')}` as Hex32,
  })
}

describe('demo authorization-boundary trace', () => {
  it('records accepted wallet and reverted direct authorization boundaries', () => {
    const flow = workflow()
    const trace = new AuthorizationTraceRecorder()
    trace.record({side: 'alice', prepared: flow.partyAuthorization, signatureVerifier: VERIFIER, authenticatedSubmitter: ALICE}, {status: 'accepted', transactionHash: ALICE_TX})
    trace.record({side: 'bob', prepared: flow.counterpartyAuthorization, signatureVerifier: VERIFIER, authenticatedSubmitter: BOB}, {status: 'reverted', errorName: 'InvalidPQAuthorization'})
    const artifact = trace.artifact()
    expect(artifact.schema).toBe(AUTHORIZATION_TRACE_SCHEMA)
    expect(artifact.records).toEqual([
      expect.objectContaining({sequence: 1, side: 'alice', chainId: '31337', authorizationMode: 'quip-wallet', wallet: WALLET, gateway: null, signatureVerifier: VERIFIER, commitPayloadHash: flow.partyAuthorization.payloadHash, authenticatedSubmitter: ALICE, actionNonce: flow.partyAuthorization.payload.actionNonce, expiry: '90', status: 'accepted', transactionHash: ALICE_TX, errorName: null}),
      expect.objectContaining({sequence: 2, side: 'bob', chainId: '31338', authorizationMode: 'registered-direct', wallet: null, gateway: GATEWAY, signatureVerifier: VERIFIER, commitPayloadHash: flow.counterpartyAuthorization.payloadHash, authenticatedSubmitter: BOB, actionNonce: flow.counterpartyAuthorization.payload.actionNonce, expiry: '190', status: 'reverted', transactionHash: null, errorName: 'InvalidPQAuthorization'}),
    ])
    expect(serializeAuthorizationTrace(artifact)).not.toMatch(/bobCommitSecret|settlementSecret|commitData/)
  })

  it('rejects mislabeled or tampered authorization evidence', () => {
    const flow = workflow()
    const trace = new AuthorizationTraceRecorder()
    expect(() => trace.record({side: 'bob', prepared: flow.partyAuthorization, signatureVerifier: VERIFIER, authenticatedSubmitter: ALICE}, {status: 'accepted', transactionHash: ALICE_TX})).toThrow('side')
    expect(() => trace.record({side: 'alice', prepared: {...flow.partyAuthorization, payloadHash: `0x${'ff'.repeat(32)}` as Hex32}, signatureVerifier: VERIFIER, authenticatedSubmitter: ALICE}, {status: 'accepted', transactionHash: ALICE_TX})).toThrow('payload hash')
    expect(() => trace.record({side: 'bob', prepared: flow.counterpartyAuthorization, signatureVerifier: VERIFIER, authenticatedSubmitter: BOB}, {status: 'reverted', errorName: ' '})).toThrow('error name')
  })

  it('refuses sensitive fields in serialized trace artifacts', () => {
    expect(() => serializeAuthorizationTrace({schema: AUTHORIZATION_TRACE_SCHEMA, records: [], signature: '0xdead'} as never)).toThrow('sensitive field')
  })
})
