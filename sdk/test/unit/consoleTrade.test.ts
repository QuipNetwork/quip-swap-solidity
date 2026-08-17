import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {
  CONSOLE_CONFIG_SCHEMA,
  PREPARE_TRADE_INPUT_SCHEMA,
  PUBLIC_OFFER_SCHEMA,
  TRADE_ACCEPTANCE_SCHEMA,
  ALICE_COMMIT_INPUT_SCHEMA,
  CrossChainLegState,
  WrapperMode,
  acceptConsoleTrade,
  initializePartyWorkspace,
  inspectPartyWorkspace,
  loadConsoleConfigIdentity,
  prepareConsoleTrade,
  importConsoleOffer,
  timingPolicyId,
  submitAliceCommit,
  restoreWorkspaceWorkflowState,
  observeAliceCommit,
} from '../../src/index.js'
import type {AliceCommitBoundary, AliceCommitObservationBoundary, Hex32, TimingPolicy} from '../../src/index.js'

const A = '0x1111111111111111111111111111111111111111' as Address
const B = '0x2222222222222222222222222222222222222222' as Address
const E = '0x3333333333333333333333333333333333333333' as Address
const V = '0x4444444444444444444444444444444444444444' as Address
const W = '0x5555555555555555555555555555555555555555' as Address
const T1 = '0x6666666666666666666666666666666666666666' as Address
const T2 = '0x7777777777777777777777777777777777777777' as Address
const H = (n: number) => `0x${n.toString(16).padStart(64, '0')}` as Hex32
const policy: TimingPolicy = {policyVersion: 1n, mode: WrapperMode.CrossChain, partyChainId: 31337n, counterpartyChainId: 31338n, partyToCounterpartyDelay: 10n, counterpartyToPartyDelay: 10n}
const input = `${JSON.stringify({schema: PREPARE_TRADE_INPUT_SCHEMA, partyCommitmentDeadline: '100', counterpartyCommitmentDeadline: '200', partyClaimDeadline: '1000', counterpartyClaimDeadline: '1100', partyReclaimRelease: '1400', counterpartyReclaimRelease: '1300', partyAuthorizationExpiry: '500', counterpartyAuthorizationExpiry: '600'})}\n`

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'quip-trade-'))
  const exchange = join(root, 'exchange')
  const aliceRoot = join(root, 'alice')
  const bobRoot = join(root, 'bob')
  const addresses = {assetSupportRegistry: A, timingPolicyRegistry: B, identityRegistry: E, authorizationGateway: V, crossChainWrapper: W, sameChainWrapper: A}
  const deploymentChain = (chainId: number, token: Address, amount: string, principal: Address) => ({chainId, trustedVerifier: V, addresses, funding: {token, amount, principal}})
  const base = {schema: CONSOLE_CONFIG_SCHEMA, networkId: 'trade-test', prototype: true, mockVerifier: true, requiredConfirmations: 3, chains: [{chainId: 31337, rpcUrl: 'http://127.0.0.1:8545'}, {chainId: 31338, rpcUrl: 'http://127.0.0.1:8546'}], actors: {alice: A, bob: B, permissionlessExecutor: E}, timingPolicy: {policyVersion: '1', mode: 'CrossChain', partyChainId: '31337', counterpartyChainId: '31338', partyToCounterpartyDelay: '10', counterpartyToPartyDelay: '10', timingPolicyId: timingPolicyId(policy)}, artifactExchange: {directory: exchange}, deployment: {schema: 'quip-swap-demo-deployment.v1', chains: [deploymentChain(31337, T1, '10', A), deploymentChain(31338, T2, '20', B)]}}
  const aliceConfig = join(root, 'alice.json'); const bobConfig = join(root, 'bob.json')
  await writeFile(aliceConfig, `${JSON.stringify({...base, localParty: 'alice'})}\n`, {mode: 0o600})
  await writeFile(bobConfig, `${JSON.stringify({...base, localParty: 'bob'})}\n`, {mode: 0o600})
  const aliceIdentity = await loadConsoleConfigIdentity(aliceConfig); const bobIdentity = await loadConsoleConfigIdentity(bobConfig)
  await initializePartyWorkspace({root: aliceRoot, party: 'alice', config: aliceIdentity})
  await initializePartyWorkspace({root: bobRoot, party: 'bob', config: bobIdentity})
  return {root, aliceRoot, bobRoot, aliceConfig, bobConfig, aliceIdentity, bobIdentity}
}

describe('console trade offer exchange', () => {
  it('prepares privately, imports publicly, and records explicit Bob acceptance', async () => {
    const value = await fixture()
    try {
      const offer = await prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input})
      expect(offer.schema).toBe(PUBLIC_OFFER_SCHEMA)
      const serialized = JSON.stringify(offer)
      expect(serialized).not.toMatch(/settlementSecret|bobCommitSecret|privateKey|signature/i)
      expect(await readFile(join(value.aliceRoot, 'public', 'offer.json'), 'utf8')).not.toMatch(/settlementSecret|bobCommitSecret/i)
      expect(await readFile(join(value.aliceRoot, 'private', '000000000001.json'), 'utf8')).toContain('settlementSecret')
      await expect(importConsoleOffer({workspace: value.bobRoot, configPath: value.bobConfig, input: serialized})).resolves.toEqual(offer)
      const acceptance = await acceptConsoleTrade({workspace: value.bobRoot, configPath: value.bobConfig})
      expect(acceptance).toEqual({schema: TRADE_ACCEPTANCE_SCHEMA, networkId: 'trade-test', tradeId: offer.tradeId, bob: B})
      expect(await inspectPartyWorkspace(value.bobRoot, {party: 'bob', networkId: 'trade-test', configDigest: value.bobIdentity.digest})).toMatchObject({tradeId: offer.tradeId, generation: 1})
      await expect(acceptConsoleTrade({workspace: value.bobRoot, configPath: value.bobConfig})).rejects.toThrow('already accepted')
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })

  it('rejects tampered public hashes without advancing Bob state', async () => {
    const value = await fixture()
    try {
      const offer = await prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input})
      const tampered = {...offer, authorizationEvidence: {...offer.authorizationEvidence, counterpartyActionNonce: H(99)}}
      await expect(importConsoleOffer({workspace: value.bobRoot, configPath: value.bobConfig, input: JSON.stringify(tampered)})).rejects.toThrow('authorization hash')
      expect(await inspectPartyWorkspace(value.bobRoot, {party: 'bob', networkId: 'trade-test', configDigest: value.bobIdentity.digest})).toMatchObject({tradeId: null, generation: 0})
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })

  it('rejects secret-bearing preparation input before changing Alice state', async () => {
    const value = await fixture()
    try {
      await expect(prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input: JSON.stringify({...JSON.parse(input), settlementSecret: H(1)})})).rejects.toThrow('forbidden')
      expect(await inspectPartyWorkspace(value.aliceRoot, {party: 'alice', networkId: 'trade-test', configDigest: value.aliceIdentity.digest})).toMatchObject({tradeId: null, generation: 0})
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })
})

describe('console Alice commit', () => {
  it('requires exact Bob acceptance, journals once, and reconciles retry without resubmission', async () => {
    const value = await fixture()
    try {
      const offer = await prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input})
      const transactionHash = H(800)
      let submissions = 0
      const boundary: AliceCommitBoundary = {
        state: async () => CrossChainLegState.Unused,
        transaction: async hash => hash === transactionHash ? 'pending' : 'missing',
        submit: async args => { submissions += 1; expect(args.payloadHash).toBe(offer.bobState.derived.partyCommitPayloadHash); return {hash: transactionHash, nonce: 7, submittedAtBlock: 10n} },
      }
      const commitInput = JSON.stringify({schema: ALICE_COMMIT_INPUT_SCHEMA, confirmed: true, acceptance: {schema: TRADE_ACCEPTANCE_SCHEMA, networkId: 'trade-test', tradeId: offer.tradeId, bob: B}})
      const first = await submitAliceCommit({workspace: value.aliceRoot, configPath: value.aliceConfig, input: commitInput, boundary})
      expect(first).toMatchObject({transactionHash, lifecycle: 'pending', reused: false})
      expect(submissions).toBe(1)
      expect(JSON.parse(await readFile(join(value.aliceRoot, 'journal', 'alice-commit.json'), 'utf8'))).toMatchObject({tradeId: offer.tradeId, transactionHash})
      expect((await restoreWorkspaceWorkflowState(value.aliceRoot, {party: 'alice', networkId: 'trade-test', configDigest: value.aliceIdentity.digest})).publicState.aliceCommit.status).toBe('pending')
      const retry = await submitAliceCommit({workspace: value.aliceRoot, configPath: value.aliceConfig, input: commitInput, boundary})
      expect(retry).toMatchObject({transactionHash, lifecycle: 'pending', reused: true})
      expect(submissions).toBe(1)
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })

  it('persists independently verified non-final and final observations for both parties', async () => {
    const value = await fixture()
    try {
      const offer = await prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input})
      await importConsoleOffer({workspace: value.bobRoot, configPath: value.bobConfig, input: JSON.stringify(offer)})
      const transactionHash = H(802)
      const commitBoundary: AliceCommitBoundary = {state: async () => CrossChainLegState.Unused, transaction: async () => 'pending', submit: async () => ({hash: transactionHash, nonce: 9, submittedAtBlock: 10n})}
      const commitInput = JSON.stringify({schema: ALICE_COMMIT_INPUT_SCHEMA, confirmed: true, acceptance: {schema: TRADE_ACCEPTANCE_SCHEMA, networkId: 'trade-test', tradeId: offer.tradeId, bob: B}})
      await submitAliceCommit({workspace: value.aliceRoot, configPath: value.aliceConfig, input: commitInput, boundary: commitBoundary})
      const inclusion = {transactionHash, blockNumber: '10', blockHash: H(803)}
      const nonFinal: AliceCommitObservationBoundary = {inspect: async () => ({lifecycle: 'included-non-final', observedHead: '10', confirmations: '1', inclusion})}
      expect(await observeAliceCommit({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary: nonFinal})).toMatchObject({lifecycle: 'included-non-final', bobCommitEnabled: false})
      expect((await restoreWorkspaceWorkflowState(value.aliceRoot, {party: 'alice', networkId: 'trade-test', configDigest: value.aliceIdentity.digest})).publicState.aliceCommit.status).toBe('included-non-final')
      const final: AliceCommitObservationBoundary = {inspect: async () => ({lifecycle: 'final', observedHead: '12', confirmations: '3', inclusion})}
      expect(await observeAliceCommit({workspace: value.bobRoot, configPath: value.bobConfig, boundary: final})).toMatchObject({lifecycle: 'final', bobCommitEnabled: true})
      expect((await restoreWorkspaceWorkflowState(value.bobRoot, {party: 'bob', networkId: 'trade-test', configDigest: value.bobIdentity.digest})).publicState).toMatchObject({stage: 'bob-enabled', aliceCommit: {status: 'final'}})
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })

  it('rejects mismatched acceptance and untracked used on-chain state without funding', async () => {
    const value = await fixture()
    try {
      const offer = await prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input})
      let submissions = 0
      const boundary: AliceCommitBoundary = {state: async () => CrossChainLegState.Committed, transaction: async () => 'missing', submit: async () => { submissions += 1; return {hash: H(801), nonce: 8, submittedAtBlock: 10n} }}
      const makeInput = (tradeId: Hex32) => JSON.stringify({schema: ALICE_COMMIT_INPUT_SCHEMA, confirmed: true, acceptance: {schema: TRADE_ACCEPTANCE_SCHEMA, networkId: 'trade-test', tradeId, bob: B}})
      await expect(submitAliceCommit({workspace: value.aliceRoot, configPath: value.aliceConfig, input: makeInput(H(99)), boundary})).rejects.toThrow('does not match')
      await expect(submitAliceCommit({workspace: value.aliceRoot, configPath: value.aliceConfig, input: makeInput(offer.tradeId), boundary})).rejects.toThrow('already used on-chain')
      expect(submissions).toBe(0)
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })
})
