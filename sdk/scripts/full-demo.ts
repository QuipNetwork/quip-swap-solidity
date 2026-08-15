import {concatHex, encodeAbiParameters, encodeFunctionData, getAddress, sliceHex} from 'viem'
import type {Address, Hash, Hex, TransactionReceipt} from 'viem'
import {
  AssetType,
  AuthorizationMode,
  DelegationPolicy,
  KeyRole,
  WrapperMode,
  applyPartyCommand,
  commitPayloadHash,
  createProtocolClient,
  crossChainWrapperAbi,
  keyPossessionDigest,
  pqAuthorizationGatewayAbi,
  prepareTradeCommand,
  registrationDigest,
  timingPolicyId,
  trustedClientStatus,
} from '../src/index.js'
import type {ClientState, CommitAuthorizationRequest, Hex32, InitialRegistration, PartySecretState, ProtocolRandomness, SideTermsTemplate, TimingPolicy} from '../src/index.js'
import {AuthorizationTraceRecorder} from './demo-authorization-trace.js'
import type {AuthorizationTraceArtifact} from './demo-authorization-trace.js'
import {bootstrapDemoEnvironment} from './demo-environment.js'
import type {DemoDeploymentArtifact} from './demo-environment.js'
import {NegativeControlRecorder} from './demo-negative-controls.js'
import type {NegativeControlArtifact, NegativeControlScenario} from './demo-negative-controls.js'
import {SettlementTraceRecorder, readCrossChainSettlementSnapshot} from './demo-settlement-trace.js'
import type {CrossChainSettlementSnapshot, SettlementTraceArtifact, TrackedHolding} from './demo-settlement-trace.js'
import type {ChainContext, FoundryArtifact} from '../test/helpers/chain.js'

export const FULL_DEMO_SCHEMA = 'quip-swap-full-demo.v1' as const
const ZERO_ADDRESS = getAddress('0x0000000000000000000000000000000000000000')
const ZERO32 = `0x${'00'.repeat(32)}` as Hex32
const fixed = (value: number): Hex32 => `0x${value.toString(16).padStart(64, '0')}` as Hex32

export interface DemoClientTraceEntry {
  readonly sequence: number
  readonly step: string
  readonly party: 'alice' | 'bob'
  readonly status: ReturnType<typeof trustedClientStatus>
}

export interface FullDemoArtifact {
  readonly schema: typeof FULL_DEMO_SCHEMA
  readonly publicTestSecrets: true
  readonly deployment: DemoDeploymentArtifact
  readonly tradeId: Hex32
  readonly terms: ClientState['terms']
  readonly lock: Hex32
  readonly deterministicSecrets: {readonly settlementSecret: Hex32; readonly bobCommitSecret: Hex32}
  readonly clientTrace: readonly DemoClientTraceEntry[]
  readonly authorizationTrace: AuthorizationTraceArtifact
  readonly settlementTrace: SettlementTraceArtifact
  readonly negativeControls: NegativeControlArtifact
}

export async function runFullDemo(
  chainA: ChainContext,
  chainB: ChainContext,
  load: (solFile: string, contract: string) => FoundryArtifact,
): Promise<FullDemoArtifact> {
  const deployment = await bootstrapDemoEnvironment(chainA, chainB, load)
  await Promise.all([chainA.warpTo(4_000_000_000n), chainB.warpTo(4_000_000_000n)])
  const localPolicy: TimingPolicy = {policyVersion: 1n, mode: WrapperMode.CrossChain, partyChainId: 31_337n, counterpartyChainId: 31_338n, partyToCounterpartyDelay: 10n, counterpartyToPartyDelay: 10n}
  if (deployment.chains.some(chain => chain.localCrossChainPolicyId !== timingPolicyId(localPolicy))) throw new Error('local timing policy mismatch')
  const now = await latestTime(chainA, chainB)
  const partySide = sideTemplate(chainA, chainB.bob.address, deployment.chains[0].funding.token, 10n * 10n ** 18n, now + 100n, now + 1_000n, now + 1_400n)
  const counterpartySide = sideTemplate(chainB, chainA.alice.address, deployment.chains[1].funding.token, 20n * 10n ** 18n, now + 200n, now + 1_100n, now + 1_300n)
  const randomness: ProtocolRandomness = {settlementSecret: fixed(1), bobCommitSecret: fixed(2), partySideNonce: fixed(3), counterpartySideNonce: fixed(4), partyActionNonce: fixed(5), counterpartyActionNonce: fixed(6)}
  const prepared = prepareTradeCommand({workflow: {policy: localPolicy, partySide, counterpartySide, partyVerifier: deployment.chains[0].addresses.authorizationGateway, counterpartyVerifier: deployment.chains[1].addresses.authorizationGateway, partyWrapper: deployment.chains[0].addresses.crossChainWrapper, counterpartyWrapper: deployment.chains[1].addresses.crossChainWrapper, partyExpiry: now + 500n, counterpartyExpiry: now + 600n, requiredConfirmations: 3n, selectedBobSubmitter: chainB.bob.address, randomness}, finalClaimExecutors: [chainA.charlie.address], secretMode: 'unsafe-demo'})
  let alice = prepared.alice
  let bob = prepared.bob
  const terms = restoreTerms(alice.publicState)
  const lock = alice.publicState.derived.settlementLock
  const clientTrace: DemoClientTraceEntry[] = []
  const recordClient = (step: string, state: ClientState) => clientTrace.push({sequence: clientTrace.length + 1, step, party: state.party, status: trustedClientStatus(state)})
  recordClient('prepare', alice.publicState); recordClient('prepare', bob.publicState)
  const authorization = new AuthorizationTraceRecorder()
  const settlement = new SettlementTraceRecorder()
  const negatives = new NegativeControlRecorder()
  const addressesA = deployment.chains[0].addresses
  const addressesB = deployment.chains[1].addresses
  const clientA = createProtocolClient({addresses: addressesA, publicClient: chainA.publicClient, walletClient: chainA.alice.walletClient})
  const clientB = createProtocolClient({addresses: addressesB, publicClient: chainB.publicClient, walletClient: chainB.bob.walletClient})
  const alicePrepared = preparedAuthorization(terms, true, addressesA.authorizationGateway, addressesA.crossChainWrapper, lock, randomness.partyActionNonce, now + 500n)
  const bobPrepared = preparedAuthorization(terms, false, addressesB.authorizationGateway, addressesB.crossChainWrapper, lock, randomness.counterpartyActionNonce, now + 600n)
  const aliceKey = pqKey(deployment.chains[0].trustedVerifier, fixed(101))
  const aliceRecovery = pqKey(deployment.chains[0].trustedVerifier, fixed(102))
  const bobKey = pqKey(deployment.chains[1].trustedVerifier, fixed(103))
  const bobRecovery = pqKey(deployment.chains[1].trustedVerifier, fixed(104))
  const holdingsA = tracked(deployment.chains[0].funding.token, chainA.alice.address, chainB.bob.address, addressesA.crossChainWrapper)
  const holdingsB = tracked(deployment.chains[1].funding.token, chainB.bob.address, chainA.alice.address, addressesB.crossChainWrapper)
  const snapshotA = () => readCrossChainSettlementSnapshot({publicClient: chainA.publicClient, chainId: 31_337, wrapper: addressesA.crossChainWrapper, terms, party: true, lock, holdings: holdingsA})
  const snapshotB = () => readCrossChainSettlementSnapshot({publicClient: chainB.publicClient, chainId: 31_338, wrapper: addressesB.crossChainWrapper, terms, party: false, lock, holdings: holdingsB})

  const aliceBefore = await snapshotA()
  const aliceRequest = request(alicePrepared, ZERO32)
  const aliceSignature = pqSignature(aliceKey, alicePrepared.payloadHash)
  const aliceHash = await lazyCommit(chainA, clientA, deployment.chains[0], aliceRequest, alicePrepared.payloadHash, aliceKey, aliceRecovery, fixed(201), now + 500n, aliceSignature)
  const aliceReceipt = await receipt(chainA, aliceHash)
  const aliceAfter = await snapshotA()
  authorization.record({side: 'alice', prepared: alicePrepared, signatureVerifier: deployment.chains[0].trustedVerifier, authenticatedSubmitter: chainA.alice.address}, {status: 'accepted', transactionHash: aliceHash})
  settlement.record({action: 'alice-commit', receipt: aliceReceipt, addresses: addressesA, before: aliceBefore, after: aliceAfter, progressionGate: 'not-required'})

  alice = applied(alice, {command: 'mark-alice-pending'}); recordClient('pending', alice.publicState)
  const aliceInclusion = inclusion(aliceReceipt)
  alice = applied(alice, {command: 'mark-alice-included-non-final', inclusion: aliceInclusion}); recordClient('included-non-final', alice.publicState)
  await chainA.testClient.mine({blocks: 2})
  alice = applied(alice, {command: 'mark-alice-final', inclusion: aliceInclusion}); recordClient('final', alice.publicState)
  const released = applyPartyCommand(alice.publicState, alice.secretState, {command: 'release-bob-secret', aliceAddress: chainA.alice.address})
  if (released.transfer === undefined) throw new Error('progression transfer missing')
  alice = {publicState: released.publicState as typeof alice.publicState, secretState: released.secretState as typeof alice.secretState}; recordClient('secret-release', alice.publicState)

  const bobBefore = await snapshotB()
  const bobRequest = request(bobPrepared, randomness.bobCommitSecret)
  const bobSignature = pqSignature(bobKey, bobPrepared.payloadHash)
  const bobHash = await lazyCommit(chainB, clientB, deployment.chains[1], bobRequest, bobPrepared.payloadHash, bobKey, bobRecovery, fixed(202), now + 600n, bobSignature)
  const bobReceipt = await receipt(chainB, bobHash)
  const bobAfter = await snapshotB()
  authorization.record({side: 'bob', prepared: bobPrepared, signatureVerifier: deployment.chains[1].trustedVerifier, authenticatedSubmitter: chainB.bob.address}, {status: 'accepted', transactionHash: bobHash})
  settlement.record({action: 'bob-commit', receipt: bobReceipt, addresses: addressesB, before: bobBefore, after: bobAfter, progressionGate: 'bob-secret-accepted'})
  bob = applied(bob, {command: 'submit-bob-commit', transfer: released.transfer, transactionHash: bobHash}); recordClient('bob-commit', bob.publicState)

  await runBobNegative(negatives, 'commit-disallowed-submitter', chainB, addressesB, snapshotB, terms, lock, fixed(7), randomness.bobCommitSecret, bobKey, chainB.charlie.address, now + 700n)
  await runBobNegative(negatives, 'bob-commit-missing-secret', chainB, addressesB, snapshotB, terms, lock, fixed(8), ZERO32, bobKey, chainB.bob.address, now + 700n)
  await runBobNegative(negatives, 'bob-commit-wrong-secret', chainB, addressesB, snapshotB, terms, lock, fixed(9), fixed(99), bobKey, chainB.bob.address, now + 700n)

  const revealBefore = await snapshotB()
  const aliceOnB = createProtocolClient({addresses: addressesB, publicClient: chainB.publicClient, walletClient: chainB.alice.walletClient})
  const revealHash = await aliceOnB.claimCrossChain(terms, false, lock, randomness.settlementSecret)
  const revealReceipt = await receipt(chainB, revealHash)
  settlement.record({action: 'revealing-claim', receipt: revealReceipt, addresses: addressesB, before: revealBefore, after: await snapshotB(), progressionGate: 'not-applicable'})
  await chainB.testClient.mine({blocks: 2})
  bob = applied(bob, {command: 'observe-reveal', settlementSecret: randomness.settlementSecret, inclusion: inclusion(revealReceipt)}); recordClient('revealing-claim-final', bob.publicState)

  await negatives.execute({scenario: 'final-claim-wrong-secret', snapshot: snapshotA, attempt: async () => { await chainA.publicClient.simulateContract({address: addressesA.crossChainWrapper, abi: crossChainWrapperAbi, functionName: 'claim', args: [terms, true, lock, fixed(100)], account: chainA.charlie.address}) }})
  const finalBefore = await snapshotA()
  const executor = createProtocolClient({addresses: addressesA, publicClient: chainA.publicClient, walletClient: chainA.charlie.walletClient})
  const finalHash = await executor.claimCrossChain(terms, true, lock, randomness.settlementSecret)
  const finalReceipt = await receipt(chainA, finalHash)
  settlement.record({action: 'final-claim', receipt: finalReceipt, addresses: addressesA, before: finalBefore, after: await snapshotA(), progressionGate: 'not-applicable'})
  bob = applied(bob, {command: 'handoff-final-claim', executor: chainA.charlie.address, transactionHash: finalHash}); recordClient('final-claim-handoff', bob.publicState)
  alice = applied(alice, {command: 'mark-complete'}); bob = applied(bob, {command: 'mark-complete'}); recordClient('completion', alice.publicState); recordClient('completion', bob.publicState)

  const artifact: FullDemoArtifact = {schema: FULL_DEMO_SCHEMA, publicTestSecrets: true, deployment, tradeId: alice.publicState.tradeId, terms: alice.publicState.terms, lock, deterministicSecrets: {settlementSecret: randomness.settlementSecret, bobCommitSecret: randomness.bobCommitSecret}, clientTrace, authorizationTrace: authorization.artifact(), settlementTrace: settlement.artifact(), negativeControls: negatives.artifact({requireAll: true})}
  assertComplete(artifact, chainA, chainB)
  return artifact
}

function sideTemplate(ctx: ChainContext, recipient: Address, token: Address, amount: bigint, commitmentDeadline: bigint, claimDeadline: bigint, reclaimRelease: bigint): SideTermsTemplate {
  return {chainId: BigInt(ctx.chainId), assets: [{assetType: AssetType.ERC20, target: token, id: 0n, amount}], principal: ctx.chainId === 31_337 ? ctx.alice.address : ctx.bob.address, authorizationMode: AuthorizationMode.RegisteredDirect, principalKeyVersion: 1n, reclaimRecipient: ctx.chainId === 31_337 ? ctx.alice.address : ctx.bob.address, recipient, commitmentDeadline, claimDeadline, reclaimRelease, delegationPolicy: DelegationPolicy.NotAllowed, delegate: ZERO_ADDRESS, delegateKeyVersion: 0n}
}
function restoreTerms(state: ClientState) { return {timingPolicyId: state.terms.timingPolicyId, partySide: restoreSide(state.terms.partySide), counterpartySide: restoreSide(state.terms.counterpartySide)} }
function restoreSide(side: ClientState['terms']['partySide']) { return {...side, chainId: BigInt(side.chainId), principalKeyVersion: BigInt(side.principalKeyVersion), commitmentDeadline: BigInt(side.commitmentDeadline), claimDeadline: BigInt(side.claimDeadline), reclaimRelease: BigInt(side.reclaimRelease), delegateKeyVersion: BigInt(side.delegateKeyVersion), assets: side.assets.map(asset => ({...asset, id: BigInt(asset.id), amount: BigInt(asset.amount)}))} }
function preparedAuthorization(terms: ReturnType<typeof restoreTerms>, party: boolean, authorizationVerifier: Address, swapAddress: Address, lock: Hex32, actionNonce: Hex32, expiry: bigint) { const payload = {terms, party, authorizationVerifier, swapAddress, lock, expectedSourceState: 0, actionNonce, expiry} as const; return {payload, payloadHash: commitPayloadHash(payload)} }
function request(prepared: ReturnType<typeof preparedAuthorization>, bobCommitSecret: Hex32): CommitAuthorizationRequest { return {receiver: prepared.payload.swapAddress, terms: prepared.payload.terms, party: prepared.payload.party, lock: prepared.payload.lock, actionNonce: prepared.payload.actionNonce, bobCommitSecret, expiry: prepared.payload.expiry, commitData: '0x'} }
function pqKey(verifier: Address, seed: Hex32): Hex { return concatHex([verifier, seed]) }
function pqSignature(key: Hex, digest: Hex32): Hex { return encodeAbiParameters([{type: 'bytes'}, {type: 'bytes32'}], [sliceHex(key, 20), digest]) }
async function lazyCommit(ctx: ChainContext, client: ReturnType<typeof createProtocolClient>, deployment: DemoDeploymentArtifact['chains'][number], commitRequest: CommitAuthorizationRequest, payloadHash: Hex32, activeKey: Hex, recoveryKey: Hex, operationNonce: Hex32, expiry: bigint, commitSignature: Hex): Promise<Hash> { const registration: InitialRegistration = {eoa: ctx.chainId === 31_337 ? ctx.alice.address : ctx.bob.address, activePQKey: activeKey, recoveryPQKey: recoveryKey, commitTarget: deployment.addresses.authorizationGateway, commitPayloadHash: payloadHash, operationNonce, expiry}; const digest = registrationDigest(BigInt(ctx.chainId), deployment.addresses.identityRegistry, registration); const call = encodeFunctionData({abi: pqAuthorizationGatewayAbi, functionName: 'authorizeCommit', args: [commitRequest, commitSignature]}); return client.registerAndCommit(registration, '0x', pqSignature(activeKey, keyPossessionDigest(digest, KeyRole.Active, activeKey)), pqSignature(recoveryKey, keyPossessionDigest(digest, KeyRole.Recovery, recoveryKey)), sliceHex(call, 4)) }
async function receipt(ctx: ChainContext, hash: Hash): Promise<TransactionReceipt> { const value = await ctx.publicClient.waitForTransactionReceipt({hash}); if (value.status !== 'success') throw new Error(`demo transaction reverted: ${hash}`); return value }
function inclusion(receipt: TransactionReceipt) { if (receipt.blockHash === null) throw new Error('receipt lacks block hash'); return {transactionHash: receipt.transactionHash, blockNumber: receipt.blockNumber.toString(), blockHash: receipt.blockHash as Hex32} }
function applied<P extends {publicState: ClientState; secretState: PartySecretState}>(pair: P, command: Parameters<typeof applyPartyCommand>[2]): P { const value = applyPartyCommand(pair.publicState, pair.secretState, command); return {publicState: value.publicState, secretState: value.secretState} as P }
function tracked(token: Address, principal: Address, recipient: Address, wrapper: Address): readonly TrackedHolding[] { return [{assetType: 'erc20', token, account: principal}, {assetType: 'erc20', token, account: recipient}, {assetType: 'erc20', token, account: wrapper}] }
async function latestTime(a: ChainContext, b: ChainContext): Promise<bigint> { const [left, right] = await Promise.all([a.now(), b.now()]); return (left > right ? left : right) + 10n }
async function runBobNegative(recorder: NegativeControlRecorder, scenario: NegativeControlScenario, ctx: ChainContext, addresses: DemoDeploymentArtifact['chains'][number]['addresses'], snapshot: () => Promise<CrossChainSettlementSnapshot>, terms: ReturnType<typeof restoreTerms>, lock: Hex32, actionNonce: Hex32, bobCommitSecret: Hex32, key: Hex, caller: Address, expiry: bigint): Promise<void> { const prepared = preparedAuthorization(terms, false, addresses.authorizationGateway, addresses.crossChainWrapper, lock, actionNonce, expiry); const req = request(prepared, bobCommitSecret); const signature = pqSignature(key, prepared.payloadHash); await recorder.execute({scenario, snapshot, attempt: async () => { await ctx.publicClient.simulateContract({address: addresses.authorizationGateway, abi: [...pqAuthorizationGatewayAbi, ...crossChainWrapperAbi], functionName: 'authorizeCommit', args: [req, signature], account: caller} as never) }}) }
function assertComplete(artifact: FullDemoArtifact, a: ChainContext, b: ChainContext): void { const [left, right] = artifact.settlementTrace.finalSnapshots; if (artifact.authorizationTrace.records.length !== 2 || artifact.settlementTrace.transactions.length !== 4 || artifact.negativeControls.records.length !== 4 || left?.state !== 'Claimed' || right?.state !== 'Claimed') throw new Error('full demo trace is incomplete'); const balances = (snapshot: CrossChainSettlementSnapshot | undefined) => snapshot?.holdings.map(holding => 'balance' in holding ? holding.balance : null); if (JSON.stringify(balances(left)) !== JSON.stringify(['0', (10n * 10n ** 18n).toString(), '0']) || JSON.stringify(balances(right)) !== JSON.stringify(['0', (20n * 10n ** 18n).toString(), '0'])) throw new Error('full demo final balances mismatch'); if (artifact.clientTrace.at(-1)?.status.workflowStage !== 'complete' || a.chainId !== 31_337 || b.chainId !== 31_338) throw new Error('full demo did not complete') }
export function serializeFullDemo(artifact: FullDemoArtifact): string { return `${JSON.stringify(artifact, null, 2)}\n` }
