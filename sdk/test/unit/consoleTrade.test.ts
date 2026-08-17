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
  releaseBobCommitSecret,
  importBobCommitSecret,
  RELEASE_BOB_SECRET_INPUT_SCHEMA,
  BOB_COMMIT_INPUT_SCHEMA,
  submitBobCommit,
  observeBobCommit,
  REVEALING_CLAIM_INPUT_SCHEMA,
  submitRevealingClaim,
  observeReveal,
  submitFinalClaim,
  getConsoleStatus,
  submitReclaim,
} from '../../src/index.js'
import type {AliceCommitBoundary, AliceCommitObservationBoundary, BobCommitBoundary, BobCommitObservationBoundary, RevealingClaimBoundary, RevealObservationBoundary, FinalClaimBoundary, ConsoleLegStatus, ConsoleStatusBoundary, ReclaimBoundary, Hex32, TimingPolicy} from '../../src/index.js'

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

describe('console status', () => {
  const leg = (chainId: 31337 | 31338, state: ConsoleLegStatus['state'], deadlineRisk: ConsoleLegStatus['deadlineRisk'] = 'none'): ConsoleLegStatus => ({
    chainId,
    wrapper: W,
    state,
    custody: state === 'Committed' ? 'wrapper' : state === 'Claimed' ? 'recipient' : state === 'Reclaimed' ? 'reclaim-recipient' : 'principal',
    payoutVerified: state === 'Claimed' || state === 'Reclaimed',
    timestamp: '900',
    claimDeadline: '1000',
    reclaimRelease: '1400',
    deadlineRisk,
    balances: [{token: chainId === 31337 ? T1 : T2, account: W, role: 'wrapper', amount: state === 'Committed' ? '10' : '0'}],
  })

  it('reports asymmetric progress and an exact next command without mutating state', async () => {
    const value = await fixture()
    try {
      await prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input})
      const before = await readFile(join(value.aliceRoot, 'workspace.json'), 'utf8')
      const boundary: ConsoleStatusBoundary = {inspect: async () => [leg(31337, 'Committed', 'claim-window-open'), leg(31338, 'Unused')]}
      const status = await getConsoleStatus({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary})
      expect(status).toMatchObject({outcome: 'in-progress', complete: false, responsibleParty: 'alice'})
      expect(status.warnings).toContain('Asymmetric on-chain states: Committed/Unused.')
      expect(status.nextCommand).toContain('observe-alice-commit --party alice')
      expect(status.legs[0]).toMatchObject({custody: 'wrapper', balances: [{amount: '10'}]})
      expect(await readFile(join(value.aliceRoot, 'workspace.json'), 'utf8')).toBe(before)
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })

  it('requires two terminal states with verified payouts before completion', async () => {
    const value = await fixture()
    try {
      await prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input})
      const asymmetric = await getConsoleStatus({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary: {inspect: async () => [leg(31337, 'Claimed'), leg(31338, 'Committed')]}})
      expect(asymmetric).toMatchObject({outcome: 'in-progress', complete: false})
      const complete = await getConsoleStatus({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary: {inspect: async () => [leg(31337, 'Claimed'), leg(31338, 'Claimed')]}})
      expect(complete).toMatchObject({outcome: 'success', complete: true, enabledActions: [], responsibleParty: 'none', nextCommand: null})
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

  it('rechecks finality, exports once privately, and imports only the exact Bob preimage', async () => {
    const value = await fixture()
    try {
      const offer = await prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input})
      await importConsoleOffer({workspace: value.bobRoot, configPath: value.bobConfig, input: JSON.stringify(offer)})
      const transactionHash = H(810)
      await submitAliceCommit({workspace: value.aliceRoot, configPath: value.aliceConfig, input: JSON.stringify({schema: ALICE_COMMIT_INPUT_SCHEMA, confirmed: true, acceptance: {schema: TRADE_ACCEPTANCE_SCHEMA, networkId: 'trade-test', tradeId: offer.tradeId, bob: B}}), boundary: {state: async () => CrossChainLegState.Unused, transaction: async () => 'pending', submit: async () => ({hash: transactionHash, nonce: 10, submittedAtBlock: 20n})}})
      const inclusion = {transactionHash, blockNumber: '20', blockHash: H(811)}
      const final: AliceCommitObservationBoundary = {inspect: async () => ({lifecycle: 'final', observedHead: '22', confirmations: '3', inclusion})}
      const released = await releaseBobCommitSecret({workspace: value.aliceRoot, configPath: value.aliceConfig, input: JSON.stringify({schema: RELEASE_BOB_SECRET_INPUT_SCHEMA, confirmed: true}), observationBoundary: final})
      expect(released).toMatchObject({tradeId: offer.tradeId, to: B, irreversible: true})
      expect(JSON.stringify(released)).not.toMatch(/bobCommitSecret|settlementSecret/i)
      const handoff = await readFile(released.handoffPath, 'utf8')
      expect(handoff).toContain('bobCommitSecret')
      expect(await readFile(join(value.aliceRoot, 'public', '000000000004.json'), 'utf8')).not.toMatch(/bobCommitSecret|settlementSecret/i)
      const reorganized: AliceCommitObservationBoundary = {inspect: async () => ({lifecycle: 'reorganized', observedHead: '22', confirmations: '0', inclusion})}
      await expect(importBobCommitSecret({workspace: value.bobRoot, configPath: value.bobConfig, input: handoff, observationBoundary: reorganized})).rejects.toThrow('not currently final')
      const tampered = {...JSON.parse(handoff), bobCommitSecret: H(999)}
      await expect(importBobCommitSecret({workspace: value.bobRoot, configPath: value.bobConfig, input: JSON.stringify(tampered), observationBoundary: final})).rejects.toThrow('wrong preimage')
      const imported = await importBobCommitSecret({workspace: value.bobRoot, configPath: value.bobConfig, input: handoff, observationBoundary: final})
      expect(imported).toMatchObject({tradeId: offer.tradeId, from: A, imported: true})
      const bob = await restoreWorkspaceWorkflowState(value.bobRoot, {party: 'bob', networkId: 'trade-test', configDigest: value.bobIdentity.digest})
      expect(bob.publicState).toMatchObject({stage: 'bob-enabled', progression: {received: true}})
      expect(bob.secretState).toHaveProperty('bobCommitSecret')
      await expect(importBobCommitSecret({workspace: value.bobRoot, configPath: value.bobConfig, input: handoff, observationBoundary: final})).rejects.toThrow(/already received|progression/)
      await expect(observeAliceCommit({workspace: value.bobRoot, configPath: value.bobConfig, boundary: reorganized})).resolves.toMatchObject({lifecycle: 'reorganized', bobCommitEnabled: false})
      expect((await restoreWorkspaceWorkflowState(value.bobRoot, {party: 'bob', networkId: 'trade-test', configDigest: value.bobIdentity.digest})).publicState).toMatchObject({stage: 'recovery', recovery: {active: true}})
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })

  it('submits Bob secret-gated funding once and lets both parties verify the exact commit', async () => {
    const value = await fixture()
    try {
      const offer = await prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input})
      await importConsoleOffer({workspace: value.bobRoot, configPath: value.bobConfig, input: JSON.stringify(offer)})
      const aliceHash = H(820)
      await submitAliceCommit({workspace: value.aliceRoot, configPath: value.aliceConfig, input: JSON.stringify({schema: ALICE_COMMIT_INPUT_SCHEMA, confirmed: true, acceptance: {schema: TRADE_ACCEPTANCE_SCHEMA, networkId: 'trade-test', tradeId: offer.tradeId, bob: B}}), boundary: {state: async () => CrossChainLegState.Unused, transaction: async () => 'pending', submit: async () => ({hash: aliceHash, nonce: 11, submittedAtBlock: 30n})}})
      const aliceInclusion = {transactionHash: aliceHash, blockNumber: '30', blockHash: H(821)}
      const aliceFinal: AliceCommitObservationBoundary = {inspect: async () => ({lifecycle: 'final', observedHead: '32', confirmations: '3', inclusion: aliceInclusion})}
      const released = await releaseBobCommitSecret({workspace: value.aliceRoot, configPath: value.aliceConfig, input: JSON.stringify({schema: RELEASE_BOB_SECRET_INPUT_SCHEMA, confirmed: true}), observationBoundary: aliceFinal})
      await importBobCommitSecret({workspace: value.bobRoot, configPath: value.bobConfig, input: await readFile(released.handoffPath, 'utf8'), observationBoundary: aliceFinal})
      const bobHash = H(822)
      let submissions = 0
      const bobBoundary: BobCommitBoundary = {state: async () => CrossChainLegState.Unused, transaction: async hash => hash === bobHash ? 'pending' : 'missing', submit: async args => {submissions += 1; expect(args.bobCommitSecret).not.toBe(H(0)); return {hash: bobHash, nonce: 12, submittedAtBlock: 40n}}}
      const bobInput = JSON.stringify({schema: BOB_COMMIT_INPUT_SCHEMA, confirmed: true})
      await expect(submitBobCommit({workspace: value.bobRoot, configPath: value.bobConfig, input: bobInput, boundary: bobBoundary})).rejects.toThrow()
      await acceptConsoleTrade({workspace: value.bobRoot, configPath: value.bobConfig})
      const submitted = await submitBobCommit({workspace: value.bobRoot, configPath: value.bobConfig, input: bobInput, boundary: bobBoundary})
      expect(submitted).toMatchObject({transactionHash: bobHash, reused: false, lifecycle: 'pending'})
      expect(JSON.stringify(submitted)).not.toMatch(/bobCommitSecret|settlementSecret/i)
      expect((await submitBobCommit({workspace: value.bobRoot, configPath: value.bobConfig, input: bobInput, boundary: bobBoundary})).reused).toBe(true)
      expect(submissions).toBe(1)
      const bobInclusion = {transactionHash: bobHash, blockNumber: '40', blockHash: H(823)}
      const committed: BobCommitObservationBoundary = {inspect: async () => ({lifecycle: 'committed', observedHead: '40', inclusion: bobInclusion})}
      expect(await observeBobCommit({workspace: value.bobRoot, configPath: value.bobConfig, boundary: committed})).toMatchObject({lifecycle: 'committed', aliceClaimEnabled: true})
      expect(await observeBobCommit({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary: committed})).toMatchObject({lifecycle: 'committed', aliceClaimEnabled: true})
      expect((await restoreWorkspaceWorkflowState(value.aliceRoot, {party: 'alice', networkId: 'trade-test', configDigest: value.aliceIdentity.digest})).publicState.stage).toBe('bob-committed')
      const revealHash = H(824)
      let claims = 0
      const revealBoundary: RevealingClaimBoundary = {state: async () => CrossChainLegState.Committed, transaction: async hash => hash === revealHash ? 'pending' : 'missing', submit: async args => {claims += 1; expect(args.secret).not.toBe(H(0)); return {hash: revealHash, nonce: 13, submittedAtBlock: 41n}}}
      const revealInput = JSON.stringify({schema: REVEALING_CLAIM_INPUT_SCHEMA, confirmed: true})
      const reveal = await submitRevealingClaim({workspace: value.aliceRoot, configPath: value.aliceConfig, input: revealInput, boundary: revealBoundary})
      expect(reveal).toMatchObject({transactionHash: revealHash, lifecycle: 'pending', reused: false, preview: {recipient: A}})
      expect(JSON.stringify(reveal)).not.toMatch(/settlementSecret|bobCommitSecret/i)
      expect((await submitRevealingClaim({workspace: value.aliceRoot, configPath: value.aliceConfig, input: revealInput, boundary: revealBoundary})).reused).toBe(true)
      expect(claims).toBe(1)
      const aliceSecrets = (await restoreWorkspaceWorkflowState(value.aliceRoot, {party: 'alice', networkId: 'trade-test', configDigest: value.aliceIdentity.digest})).secretState
      if (aliceSecrets.party !== 'alice') throw new Error('test requires Alice secrets')
      const revealInclusion = {transactionHash: revealHash, blockNumber: '41', blockHash: H(825)}
      const nonFinalReveal: RevealObservationBoundary = {inspect: async () => ({lifecycle: 'included-non-final', observedHead: '41', confirmations: '1', inclusion: revealInclusion, secret: aliceSecrets.settlementSecret})}
      expect(await observeReveal({workspace: value.bobRoot, configPath: value.bobConfig, boundary: nonFinalReveal})).toMatchObject({lifecycle: 'included-non-final', finalClaimEnabled: false})
      const finalReveal: RevealObservationBoundary = {inspect: async () => ({lifecycle: 'final', observedHead: '43', confirmations: '3', inclusion: revealInclusion, secret: aliceSecrets.settlementSecret})}
      const observedReveal = await observeReveal({workspace: value.bobRoot, configPath: value.bobConfig, boundary: finalReveal})
      expect(observedReveal).toMatchObject({lifecycle: 'final', finalClaimEnabled: true})
      expect(JSON.stringify(observedReveal)).not.toMatch(/settlementSecret|bobCommitSecret/i)
      const finalHash = H(826)
      let finalClaims = 0
      const finalBoundary: FinalClaimBoundary = {state: async () => CrossChainLegState.Committed, transaction: async hash => hash === finalHash ? 'pending' : 'missing', submit: async args => {finalClaims += 1; expect(args.secret).toBe(aliceSecrets.settlementSecret); return finalHash}}
      const finalClaim = await submitFinalClaim({workspace: value.bobRoot, configPath: value.bobConfig, boundary: finalBoundary, executor: B})
      expect(finalClaim).toMatchObject({transactionHash: finalHash, lifecycle: 'pending', reused: false, preview: {recipient: B, successPathDelay: 'none'}})
      expect(JSON.stringify(finalClaim)).not.toMatch(/settlementSecret|bobCommitSecret/i)
      expect((await submitFinalClaim({workspace: value.bobRoot, configPath: value.bobConfig, boundary: finalBoundary, executor: B})).reused).toBe(true)
      expect(finalClaims).toBe(1)
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

describe('console reclaim and recovery', () => {
  it('reclaims only an eligible committed leg to the signed recipient and reconciles a mined replacement', async () => {
    const value = await fixture()
    try {
      const offer = await prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input})
      const hash = H(900)
      let state = CrossChainLegState.Committed
      let lifecycle: 'pending' | 'dropped' | 'reverted' | 'replaced' = 'pending'
      let submissions = 0
      const boundary: ReclaimBoundary = {
        state: async () => state,
        timestamp: async () => 1400n,
        transaction: async () => ({lifecycle, ...(lifecycle === 'replaced' ? {replacementHash: H(902)} : {})}),
        submit: async args => {submissions += 1; expect(args.party).toBe(true); expect(args.terms.partySide.reclaimRecipient).toBe(A); return {hash, nonce: 4, submittedAtBlock: 30n}},
      }
      const first = await submitReclaim({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary, submitter: E})
      expect(first).toMatchObject({tradeId: offer.tradeId, transactionHash: hash, lifecycle: 'pending', reused: false, preview: {reclaimRecipient: A, authorization: 'permissionless'}})
      lifecycle = 'dropped'
      await expect(submitReclaim({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary, submitter: E})).resolves.toMatchObject({lifecycle: 'dropped', reused: true})
      lifecycle = 'reverted'
      await expect(submitReclaim({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary, submitter: E})).resolves.toMatchObject({lifecycle: 'reverted', reused: true})
      lifecycle = 'replaced'
      await expect(submitReclaim({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary, submitter: E})).resolves.toMatchObject({transactionHash: H(902), lifecycle: 'replaced', reused: true})
      state = CrossChainLegState.Reclaimed
      const reconciled = await submitReclaim({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary, submitter: E})
      expect(reconciled).toMatchObject({transactionHash: H(902), lifecycle: 'already-mined', reused: true})
      expect(submissions).toBe(1)
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })

  it('refuses wrong state and an early reclaim without submitting', async () => {
    const value = await fixture()
    try {
      await prepareConsoleTrade({workspace: value.aliceRoot, configPath: value.aliceConfig, input})
      let state = CrossChainLegState.Unused
      let submissions = 0
      const boundary: ReclaimBoundary = {state: async () => state, timestamp: async () => 1399n, transaction: async () => ({lifecycle: 'dropped'}), submit: async () => {submissions += 1; return {hash: H(901), nonce: 1, submittedAtBlock: 1n}}}
      await expect(submitReclaim({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary, submitter: E})).rejects.toThrow('exact Committed')
      state = CrossChainLegState.Committed
      await expect(submitReclaim({workspace: value.aliceRoot, configPath: value.aliceConfig, boundary, submitter: E})).rejects.toThrow('not enabled')
      expect(submissions).toBe(0)
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })
})
