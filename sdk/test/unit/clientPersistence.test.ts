import {mkdtemp, mkdir, readFile, rm, stat, writeFile} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {
  AuthorizationMode,
  CLIENT_STATE_SCHEMA,
  DelegationPolicy,
  SECRET_STATE_SCHEMA,
  TrustedCrossChainWorkflow,
  gateContextId,
  persistProtocolTerms,
  restorePartyWorkflowState,
  savePartyWorkflowState,
  serializeClientState,
  validatePartyWorkflowState,
  WrapperMode,
} from '../../src/index.js'
import type {
  AliceClientState,
  AliceSecretState,
  BobClientState,
  BobSecretState,
  SideTerms,
  TimingPolicy,
} from '../../src/index.js'
import {AssetType} from '../../src/index.js'
import type {Hex32} from '../../src/index.js'

const ZERO = '0x0000000000000000000000000000000000000000' as Address
const ALICE = '0x1111111111111111111111111111111111111111' as Address
const BOB = '0x2222222222222222222222222222222222222222' as Address
const EXECUTOR = '0x3333333333333333333333333333333333333333' as Address
const VERIFIER = '0x4444444444444444444444444444444444444444' as Address
const WRAPPER = '0x5555555555555555555555555555555555555555' as Address
const hexN = (n: number) => `0x${n.toString(16).padStart(64, '0')}` as Hex32
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
function fixtures(generation = 1) {
  let n = 1
  const workflow = new TrustedCrossChainWorkflow({policy, partySide: side(true), counterpartySide: side(false), partyVerifier: VERIFIER, counterpartyVerifier: VERIFIER, partyWrapper: WRAPPER, counterpartyWrapper: WRAPPER, partyExpiry: 90n, counterpartyExpiry: 190n, requiredConfirmations: 3n, selectedBobSubmitter: EXECUTOR, randomHex32: () => hexN(n++)})
  const common = {
    schema: CLIENT_STATE_SCHEMA,
    generation,
    sequence: 0,
    tradeId: workflow.tradeId,
    terms: persistProtocolTerms(workflow.terms),
    derived: {gateContextId: gateContextId(workflow.terms), settlementLock: workflow.lock, partyCommitPayloadHash: workflow.partyAuthorization.payloadHash, counterpartyCommitPayloadHash: workflow.counterpartyAuthorization.payloadHash},
    selected: {bobSubmitter: EXECUTOR, finalClaimExecutors: [EXECUTOR]},
    stage: 'prepared' as const,
    aliceCommit: {status: 'not-submitted' as const},
    recovery: {active: false},
  }
  const alicePublic: AliceClientState = {...common, party: 'alice', progression: {released: false}}
  const aliceSecrets: AliceSecretState = {schema: SECRET_STATE_SCHEMA, party: 'alice', generation, tradeId: workflow.tradeId, mode: 'prototype-local', publicTestSecrets: false, settlementSecret: hexN(1), bobCommitSecret: hexN(2)}
  const bobPublic: BobClientState = {...common, party: 'bob', progression: {received: false}}
  const bobSecrets: BobSecretState = {schema: SECRET_STATE_SCHEMA, party: 'bob', generation, tradeId: workflow.tradeId, mode: 'prototype-local', publicTestSecrets: false}
  return {alicePublic, aliceSecrets, bobPublic, bobSecrets}
}

describe('party-local workflow persistence', () => {
  it('saves and restores owner-only matched generations without exposing secrets publicly', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'quip-alice-'))
    try {
      const {alicePublic, aliceSecrets} = fixtures()
      await savePartyWorkflowState(directory, alicePublic, aliceSecrets)
      const restored = await restorePartyWorkflowState(directory)
      expect(restored.publicState).toEqual(alicePublic)
      expect(restored.secretState).toEqual(aliceSecrets)
      expect(serializeClientState(restored.publicState)).not.toContain(aliceSecrets.settlementSecret)
      const generation = '000000000001'
      expect((await stat(join(directory, 'generations', `${generation}.public.json`))).mode & 0o777).toBe(0o600)
      expect((await stat(join(directory, 'generations', `${generation}.secrets.json`))).mode & 0o777).toBe(0o600)
    } finally {
      await rm(directory, {recursive: true, force: true})
    }
  })

  it('rejects swapped parties, stale generations, and incorrect preimages', () => {
    const {alicePublic, aliceSecrets, bobSecrets} = fixtures()
    expect(() => validatePartyWorkflowState(alicePublic, bobSecrets)).toThrow('party state boundary')
    expect(() => validatePartyWorkflowState(alicePublic, {...aliceSecrets, generation: 2})).toThrow('generation')
    expect(() => validatePartyWorkflowState(alicePublic, {...aliceSecrets, settlementSecret: hexN(99)})).toThrow('settlement preimage')
    expect(() => validatePartyWorkflowState(alicePublic, {...aliceSecrets, bobCommitSecret: hexN(99)})).toThrow('BobCommitSecret')
  })

  it('rejects incomplete pointed generations and never falls forward to them', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'quip-partial-'))
    try {
      const first = fixtures(1)
      await savePartyWorkflowState(directory, first.alicePublic, first.aliceSecrets)
      const generations = join(directory, 'generations')
      const second = fixtures(2)
      await writeFile(join(generations, '000000000002.public.json'), serializeClientState(second.alicePublic), {mode: 0o600})
      expect((await restorePartyWorkflowState(directory)).publicState.generation).toBe(1)
      await writeFile(join(directory, 'current'), '000000000002\n', {mode: 0o600})
      await expect(restorePartyWorkflowState(directory)).rejects.toThrow('incomplete or corrupt')
    } finally {
      await rm(directory, {recursive: true, force: true})
    }
  })

  it('keeps Bob empty until release and validates unsafe-demo labeling', () => {
    const {bobPublic, bobSecrets, alicePublic, aliceSecrets} = fixtures()
    expect(validatePartyWorkflowState(bobPublic, bobSecrets).secretState).toEqual(bobSecrets)
    expect(() => validatePartyWorkflowState({...bobPublic, progression: {received: true}}, bobSecrets)).toThrow('receipt')
    const demo = {...aliceSecrets, mode: 'unsafe-demo', publicTestSecrets: true} as const
    expect(validatePartyWorkflowState(alicePublic, demo).secretState.publicTestSecrets).toBe(true)
    expect(() => validatePartyWorkflowState(alicePublic, {...demo, publicTestSecrets: false})).toThrow('marker')
  })
})
