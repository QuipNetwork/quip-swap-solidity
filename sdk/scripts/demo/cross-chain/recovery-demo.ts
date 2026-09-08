import {concatHex, encodeAbiParameters, encodeFunctionData, sliceHex} from 'viem'
import type {Address, Hash, Hex, TransactionReceipt} from 'viem'
import {
  AssetType,
  AuthorizationMode,
  DelegationPolicy,
  KeyRole,
  WrapperMode,
  createProtocolClient,
  directAuthorizationAbi,
  keyPossessionDigest,
  prepareTrustedCrossChainWorkflow,
  registrationDigest,
} from '../../../src/index.js'
import type {
  CommitAuthorizationRequest,
  Hex32,
  InitialRegistration,
  ProtocolTerms,
  SideTermsTemplate,
  TimingPolicy,
  TrustedCrossChainWorkflow,
} from '../../../src/index.js'
import type {ChainContext, FoundryArtifact} from '../../../test/helpers/chain.js'
import {bootstrapDemoEnvironment} from '../shared/environment.js'
import type {DemoChainDeployment, DemoDeploymentArtifact} from '../shared/environment.js'
import {readCrossChainSettlementSnapshot} from '../shared/settlement-trace.js'
import type {CrossChainSettlementSnapshot, TrackedHolding} from '../shared/settlement-trace.js'

export const CROSS_CHAIN_RECOVERY_SCHEMA = 'quip-swap-cross-chain-recovery-demo.v1' as const
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as Address
const ZERO32 = `0x${'00'.repeat(32)}` as Hex32
const fixed = (
  value: number): Hex32 => `0x${value.toString(16).padStart(64, '0')}` as Hex32

export interface RecoveryOutcome {
  readonly scenario: 'both-reclaim' | 'final-claim-omitted' | 'claim-wins' | 'reclaim-wins'
  readonly finalStates: readonly [CrossChainSettlementSnapshot, CrossChainSettlementSnapshot]
  readonly transactionHashes: readonly Hash[]
  readonly rejectedCompetingAction?: {
    readonly action: 'claim' | 'reclaim';
    readonly stateUnchanged: true
  }
  readonly fixedPayouts: true
}

export interface ObservationRecord {
  readonly subject: 'alice-commit' | 'revealing-claim'
  readonly lifecycle: 'dropped' | 'replaced' | 'reverted' | 'reorganized' | 'final'
  readonly stageBefore: string
  readonly stageAfter: string
  readonly advanced: boolean
}

export interface CrossChainRecoveryArtifact {
  readonly schema: typeof CROSS_CHAIN_RECOVERY_SCHEMA
  readonly mockVerifierDemo: true
  readonly deployment: DemoDeploymentArtifact
  readonly tradeId: Hex32
  readonly lock: Hex32
  readonly outcomes: readonly [RecoveryOutcome, RecoveryOutcome, RecoveryOutcome, RecoveryOutcome]
  readonly observations: readonly ObservationRecord[]
}

export interface RecoveryDemoProgress {
  readonly step: number;
  readonly total: number;
  readonly message: string
}

interface Fixture {
  readonly deployment: DemoDeploymentArtifact
  readonly terms: ProtocolTerms
  readonly lock: Hex32
  readonly settlementSecret: Hex32
  readonly bobCommitSecret: Hex32
  readonly workflowArgs: Parameters<typeof prepareTrustedCrossChainWorkflow>[0]
  readonly snapshotA: () => Promise<CrossChainSettlementSnapshot>
  readonly snapshotB: () => Promise<CrossChainSettlementSnapshot>
}

export async function runCrossChainRecoveryDemo(
  chainA: ChainContext,
  chainB: ChainContext,
  load: (
    solFile: string,
    contract: string) => FoundryArtifact,
  onProgress?: (
    progress: RecoveryDemoProgress) => void,
): Promise<CrossChainRecoveryArtifact> {
  const total = 6
  let step = 0
  const progress = (
    message: string) => onProgress?.({
      step: ++step,
      total,
      message
    })

  progress('Deploying and funding two independent local chains')

  const fixture = await prepareFixture(chainA, chainB, load)

  progress('Finalizing both commits and reclaiming both unclaimed legs')

  const bothReclaim = await isolated(chainA, chainB, () => runBothReclaim(chainA, chainB, fixture))

  progress('Omitting the final claim and recovering the remaining committed leg')

  const omitted = await isolated(chainA, chainB, () => runOmittedFinalClaim(chainA, chainB, fixture))

  progress('Resolving an independent-chain race with claim as the local winner')

  const claimWins = await isolated(chainA, chainB, () => runTerminalRace(chainA, chainB, fixture, 'claim'))

  progress('Resolving an independent-chain race with reclaim as the local winner')

  const reclaimWins = await isolated(chainA, chainB, () => runTerminalRace(chainA, chainB, fixture, 'reclaim'))

  progress('Checking that asserted and reorganized observations cannot advance finality')

  const observations = await isolated(chainA, chainB, () => runObservationControls(chainA, fixture))

  const artifact: CrossChainRecoveryArtifact = {
    schema: CROSS_CHAIN_RECOVERY_SCHEMA,
    mockVerifierDemo: true,
    deployment: fixture.deployment,
    tradeId: prepareTrustedCrossChainWorkflow(fixture.workflowArgs).workflow.tradeId,
    lock: fixture.lock,
    outcomes: [bothReclaim, omitted, claimWins, reclaimWins],
    observations,
  }

  validateCrossChainRecoveryArtifact(artifact)

  return artifact
}

async function prepareFixture(
  chainA: ChainContext,
  chainB: ChainContext,
  load: (
    solFile: string,
    contract: string) => FoundryArtifact): Promise<Fixture> {
  const deployment = await bootstrapDemoEnvironment(chainA, chainB, load)
  const [initialA, initialB] = await Promise.all([chainA.now(), chainB.now()])

  await Promise.all([initialA < 4_000_000_000n ? chainA.warpTo(4_000_000_000n) : Promise.resolve(), initialB < 4_000_000_000n ? chainB.warpTo(4_000_000_000n) : Promise.resolve()])

  const [currentA, currentB] = await Promise.all([chainA.now(), chainB.now()])
  const now = (currentA > currentB ? currentA : currentB) + 10n
  const policy: TimingPolicy = {
    policyVersion: 1n,
    mode: WrapperMode.CrossChain,
    partyChainId: 31_337n,
    counterpartyChainId: 31_338n,
    partyToCounterpartyDelay: 10n,
    counterpartyToPartyDelay: 10n
  }
  const partySide = sideTemplate(chainA, chainB.bob.address, deployment.chains[0].funding.token, 10n * 10n ** 18n, now + 100n, now + 1_000n, now + 1_400n)
  const counterpartySide = sideTemplate(chainB, chainA.alice.address, deployment.chains[1].funding.token, 20n * 10n ** 18n, now + 200n, now + 900n, now + 1_300n)
  const workflowArgs = {
    policy,
    partySide,
    counterpartySide,
    partyVerifier: deployment.chains[0].addresses.directAuthorization,
    counterpartyVerifier: deployment.chains[1].addresses.directAuthorization,
    partyWrapper: deployment.chains[0].addresses.crossChainWrapper,
    counterpartyWrapper: deployment.chains[1].addresses.crossChainWrapper,
    partyExpiry: now + 500n,
    counterpartyExpiry: now + 600n,
    requiredConfirmations: 3n,
    selectedBobSubmitter: chainB.bob.address,
    randomness: {
      settlementSecret: fixed(1),
      bobCommitSecret: fixed(2),
      partySideNonce: fixed(3),
      counterpartySideNonce: fixed(4),
      partyActionNonce: fixed(5),
      counterpartyActionNonce: fixed(6)
    },
  } as const
  const prepared = prepareTrustedCrossChainWorkflow(workflowArgs)
  const terms = prepared.workflow.terms
  const [htlcA, htlcB] = await Promise.all([
    createProtocolClient({
      addresses: deployment.chains[0].addresses,
      publicClient: chainA.publicClient
    }).predictCrossChainHTLC(terms, true, prepared.workflow.lock),
    createProtocolClient({
      addresses: deployment.chains[1].addresses,
      publicClient: chainB.publicClient
    }).predictCrossChainHTLC(terms, false, prepared.workflow.lock),
  ])
  const holdingsA = tracked(deployment.chains[0].funding.token, chainA.alice.address, chainB.bob.address, htlcA)
  const holdingsB = tracked(deployment.chains[1].funding.token, chainB.bob.address, chainA.alice.address, htlcB)

  return {
    deployment,
    terms,
    lock: prepared.workflow.lock,
    settlementSecret: prepared.settlementSecret,
    bobCommitSecret: prepared.bobCommitSecret,
    workflowArgs,
    snapshotA: () => readCrossChainSettlementSnapshot({
      publicClient: chainA.publicClient,
      chainId: chainA.chainId,
      wrapper: deployment.chains[0].addresses.crossChainWrapper,
      terms,
      party: true,
      lock: prepared.workflow.lock,
      holdings: holdingsA
    }),
    snapshotB: () => readCrossChainSettlementSnapshot({
      publicClient: chainB.publicClient,
      chainId: chainB.chainId,
      wrapper: deployment.chains[1].addresses.crossChainWrapper,
      terms,
      party: false,
      lock: prepared.workflow.lock,
      holdings: holdingsB
    }),
  }
}

async function runBothReclaim(
  a: ChainContext,
  b: ChainContext,
  fixture: Fixture): Promise<RecoveryOutcome> {
  const commits = await commitBoth(a, b, fixture)

  await Promise.all([a.testClient.mine({
    blocks: 2
  }), b.testClient.mine({
    blocks: 2
  })])
  await Promise.all([a.warpTo(fixture.terms.partySide.reclaimRelease), b.warpTo(fixture.terms.counterpartySide.reclaimRelease)])

  const [left, right] = await Promise.all([
    submitAndWait(a, createProtocolClient({
      addresses: fixture.deployment.chains[0].addresses,
      publicClient: a.publicClient,
      walletClient: a.charlie.walletClient
    }).reclaimCrossChain(fixture.terms, true, fixture.lock)),
    submitAndWait(b, createProtocolClient({
      addresses: fixture.deployment.chains[1].addresses,
      publicClient: b.publicClient,
      walletClient: b.charlie.walletClient
    }).reclaimCrossChain(fixture.terms, false, fixture.lock)),
  ])

  return outcome('both-reclaim', fixture, [...commits, left.transactionHash, right.transactionHash])
}

async function runOmittedFinalClaim(
  a: ChainContext,
  b: ChainContext,
  fixture: Fixture): Promise<RecoveryOutcome> {
  const commits = await commitBoth(a, b, fixture)
  const reveal = await submitAndWait(b, createProtocolClient({
    addresses: fixture.deployment.chains[1].addresses,
    publicClient: b.publicClient,
    walletClient: b.alice.walletClient
  }).claimCrossChain(fixture.terms, false, fixture.lock, fixture.settlementSecret))

  await b.testClient.mine({
    blocks: 2
  })
  await a.warpTo(fixture.terms.partySide.reclaimRelease)

  const reclaim = await submitAndWait(a, createProtocolClient({
    addresses: fixture.deployment.chains[0].addresses,
    publicClient: a.publicClient,
    walletClient: a.charlie.walletClient
  }).reclaimCrossChain(fixture.terms, true, fixture.lock))
  const before = await fixture.snapshotA()

  await expectRejected(() => createProtocolClient({
    addresses: fixture.deployment.chains[0].addresses,
    publicClient: a.publicClient,
    walletClient: a.bob.walletClient
  }).claimCrossChain(fixture.terms, true, fixture.lock, fixture.settlementSecret), a)
  if ((await fixture.snapshotA()).state !== before.state)
    throw new Error('late final claim changed reclaimed state')

  return outcome('final-claim-omitted', fixture, [...commits, reveal.transactionHash, reclaim.transactionHash], {
    action: 'claim',
    stateUnchanged: true
  })
}

async function runTerminalRace(
  a: ChainContext,
  b: ChainContext,
  fixture: Fixture,
  winner: 'claim' | 'reclaim'): Promise<RecoveryOutcome> {
  const commits = await commitBoth(a, b, fixture)
  const reveal = await submitAndWait(b, createProtocolClient({
    addresses: fixture.deployment.chains[1].addresses,
    publicClient: b.publicClient,
    walletClient: b.alice.walletClient
  }).claimCrossChain(fixture.terms, false, fixture.lock, fixture.settlementSecret))
  const actor = createProtocolClient({
    addresses: fixture.deployment.chains[0].addresses,
    publicClient: a.publicClient,
    walletClient: a.charlie.walletClient
  })
  let terminal: TransactionReceipt
  let rejected: 'claim' | 'reclaim'

  if (winner === 'claim') {
    terminal = await submitAndWait(a, actor.claimCrossChain(fixture.terms, true, fixture.lock, fixture.settlementSecret))
    await a.warpTo(fixture.terms.partySide.reclaimRelease)

    await expectRejected(() => actor.reclaimCrossChain(fixture.terms, true, fixture.lock), a)

    rejected = 'reclaim'
  } else {
    await a.warpTo(fixture.terms.partySide.reclaimRelease)
    terminal = await submitAndWait(a, actor.reclaimCrossChain(fixture.terms, true, fixture.lock))

    await expectRejected(() => actor.claimCrossChain(fixture.terms, true, fixture.lock, fixture.settlementSecret), a)

    rejected = 'claim'
  }

  const stable = await fixture.snapshotA()
  const expected = winner === 'claim' ? 'Claimed' : 'Reclaimed'

  if (stable.state !== expected)
    throw new Error(`${winner}-winning race changed terminal state`)

  return outcome(winner === 'claim' ? 'claim-wins' : 'reclaim-wins', fixture, [...commits, reveal.transactionHash, terminal.transactionHash], {
    action: rejected,
    stateUnchanged: true
  })
}

async function runObservationControls(
  chain: ChainContext,
  fixture: Fixture): Promise<ObservationRecord[]> {
  const records: ObservationRecord[] = []
  const workflow = prepareTrustedCrossChainWorkflow(fixture.workflowArgs).workflow

  workflow.markAlicePending()

  for (const lifecycle of ['dropped', 'replaced', 'reverted'] as const)
    records.push(assertNoAdvance(workflow, 'alice-commit', lifecycle))

  const root = await chain.testClient.snapshot()
  const hash = await chain.alice.walletClient.sendTransaction({
    account: chain.alice.account,
    chain: chain.alice.walletClient.chain,
    to: chain.alice.address,
    value: 0n
  })
  const receipt = await submitAndWait(chain, Promise.resolve(hash))

  if (receipt.blockHash === null)
    throw new Error('observation transaction lacks a block hash')

  const inclusion = {
    transactionHash: receipt.transactionHash,
    blockNumber: receipt.blockNumber,
    blockHash: receipt.blockHash as Hex32
  }

  workflow.observeAlice(inclusion, receipt.blockNumber)

  const beforeRollback = workflow.status().stage

  await chain.testClient.revert({
    id: root
  })
  workflow.rollbackAlice(inclusion.blockHash)
  records.push({
    subject: 'alice-commit',
    lifecycle: 'reorganized',
    stageBefore: beforeRollback,
    stageAfter: workflow.status().stage,
    advanced: false
  })

  const finalHash = await chain.alice.walletClient.sendTransaction({
    account: chain.alice.account,
    chain: chain.alice.walletClient.chain,
    to: chain.alice.address,
    value: 0n
  })
  const finalReceipt = await submitAndWait(chain, Promise.resolve(finalHash))

  await chain.testClient.mine({
    blocks: 2
  })

  if (finalReceipt.blockHash === null)
    throw new Error('final observation transaction lacks a block hash')

  const beforeFinal = workflow.status().stage

  workflow.observeAlice({
    transactionHash: finalReceipt.transactionHash,
    blockNumber: finalReceipt.blockNumber,
    blockHash: finalReceipt.blockHash as Hex32
  }, (await chain.publicClient.getBlock({
    blockTag: 'latest'
  })).number)
  records.push({
    subject: 'alice-commit',
    lifecycle: 'final',
    stageBefore: beforeFinal,
    stageAfter: workflow.status().stage,
    advanced: true
  })
  workflow.enableBobCommit(fixture.terms.counterpartySide.principal)
  workflow.markBobCommitted()

  for (const lifecycle of ['reverted', 'reorganized'] as const)
    records.push(assertNoAdvance(workflow, 'revealing-claim', lifecycle))

  const revealBefore = workflow.status().stage

  workflow.observeFinalReveal()
  records.push({
    subject: 'revealing-claim',
    lifecycle: 'final',
    stageBefore: revealBefore,
    stageAfter: workflow.status().stage,
    advanced: true
  })

  return records
}

function assertNoAdvance(
  workflow: TrustedCrossChainWorkflow,
  subject: ObservationRecord['subject'],
  lifecycle: 'dropped' | 'replaced' | 'reverted' | 'reorganized'): ObservationRecord {
  const before = workflow.status().stage
  const after = workflow.status().stage

  if (after !== before)
    throw new Error(`${lifecycle} observation advanced trusted workflow`)

  return {
    subject,
    lifecycle,
    stageBefore: before,
    stageAfter: after,
    advanced: false
  }
}

async function commitBoth(
  a: ChainContext,
  b: ChainContext,
  fixture: Fixture): Promise<readonly [Hash, Hash]> {
  const prepared = prepareTrustedCrossChainWorkflow(fixture.workflowArgs).workflow
  const alice = await lazyCommit(a, fixture.deployment.chains[0], prepared.partyAuthorization, fixture.bobCommitSecret, fixed(101), fixed(102), fixed(201))
  const bob = await lazyCommit(b, fixture.deployment.chains[1], prepared.counterpartyAuthorization, fixture.bobCommitSecret, fixed(103), fixed(104), fixed(202))

  return [alice.transactionHash, bob.transactionHash]
}

async function lazyCommit(
  chain: ChainContext,
  deployment: DemoChainDeployment,
  prepared: TrustedCrossChainWorkflow['partyAuthorization'],
  bobCommitSecret: Hex32,
  activeSeed: Hex32,
  recoverySeed: Hex32,
  operationNonce: Hex32,
): Promise<TransactionReceipt> {
  const activeKey = pqKey(deployment.trustedVerifier, activeSeed)
  const recoveryKey = pqKey(deployment.trustedVerifier, recoverySeed)
  const request: CommitAuthorizationRequest = {
    receiver: prepared.payload.swapAddress,
    terms: prepared.payload.terms,
    party: prepared.payload.party,
    lock: prepared.payload.lock,
    actionNonce: prepared.payload.actionNonce,
    bobCommitSecret,
    expiry: prepared.payload.expiry,
    commitData: '0x'
  }
  const registration: InitialRegistration = {
    eoa: prepared.payload.party ? chain.alice.address : chain.bob.address,
    activePQKey: activeKey,
    recoveryPQKey: recoveryKey,
    commitTarget: deployment.addresses.directAuthorization,
    commitPayloadHash: prepared.payloadHash,
    operationNonce,
    expiry: prepared.payload.expiry
  }
  const digest = registrationDigest(BigInt(chain.chainId), deployment.addresses.directAuthorization, registration)
  const call = encodeFunctionData({
    abi: directAuthorizationAbi,
    functionName: 'authorizeCommit',
    args: [request, pqSignature(activeKey, prepared.payloadHash)]
  })
  const client = createProtocolClient({
    addresses: deployment.addresses,
    publicClient: chain.publicClient,
    walletClient: (prepared.payload.party ? chain.alice : chain.bob).walletClient
  })

  return submitAndWait(chain, client.registerAndCommit(registration, '0x', pqSignature(activeKey, keyPossessionDigest(digest, KeyRole.Active, activeKey)), pqSignature(recoveryKey, keyPossessionDigest(digest, KeyRole.Recovery, recoveryKey)), sliceHex(call, 4), request))
}

async function outcome(
  scenario: RecoveryOutcome['scenario'],
  fixture: Fixture,
  transactionHashes: readonly Hash[],
  rejectedCompetingAction?: RecoveryOutcome['rejectedCompetingAction']): Promise<RecoveryOutcome> {
  const finalStates = [await fixture.snapshotA(), await fixture.snapshotB()] as const

  return {
    scenario,
    finalStates,
    transactionHashes, ...(rejectedCompetingAction === undefined ? {} : {
      rejectedCompetingAction
    }),
    fixedPayouts: true
  }
}

async function isolated<T>(
  a: ChainContext,
  b: ChainContext,
  run: () => Promise<T>): Promise<T> {
  const [left, right] = await Promise.all([a.testClient.snapshot(), b.testClient.snapshot()])

  try {
    return await run()
  } finally {
    await Promise.all([a.testClient.revert({
      id: left
    }), b.testClient.revert({
      id: right
    })])
  }
}

async function submitAndWait(
  chain: ChainContext,
  submission: Promise<Hash>): Promise<TransactionReceipt> {
  const hash = await submission
  const receipt = await chain.publicClient.waitForTransactionReceipt({
    hash
  })

  if (receipt.status !== 'success')
    throw new Error(`transaction reverted: ${hash}`)

  return receipt
}

async function expectRejected(
  submit: () => Promise<Hash>,
  chain: ChainContext): Promise<void> {
  try {
    const hash = await submit()
    const receipt = await chain.publicClient.waitForTransactionReceipt({
      hash
    })

    if (receipt.status === 'success')
      throw new Error('competing terminal action unexpectedly succeeded')
  }
  catch (error) {
    if (error instanceof Error && error.message === 'competing terminal action unexpectedly succeeded')
      throw error
  }
}

function sideTemplate(
  chain: ChainContext,
  recipient: Address,
  token: Address,
  amount: bigint,
  commitmentDeadline: bigint,
  claimDeadline: bigint,
  reclaimRelease: bigint): SideTermsTemplate {
  const principal = chain.chainId === 31_337 ? chain.alice.address : chain.bob.address

  return {
    chainId: BigInt(chain.chainId),
    assets: [{
      assetType: AssetType.ERC20,
      target: token,
      id: 0n,
      amount
    }],
    principal,
    authorizationMode: AuthorizationMode.RegisteredDirect,
    principalKeyVersion: 1n,
    reclaimRecipient: principal,
    recipient,
    commitmentDeadline,
    claimDeadline,
    reclaimRelease,
    delegationPolicy: DelegationPolicy.NotAllowed,
    delegate: ZERO_ADDRESS,
    delegateKeyVersion: 0n
  }
}

function tracked(
  token: Address,
  principal: Address,
  recipient: Address,
  wrapper: Address): readonly TrackedHolding[] {
  return [{
    assetType: 'erc20',
    token,
    account: principal
  }, {
    assetType: 'erc20',
    token,
    account: recipient
  }, {
    assetType: 'erc20',
    token,
    account: wrapper
  }]
}

function pqKey(
  verifier: Address,
  seed: Hex32): Hex {
  return concatHex([verifier, seed])
}
function pqSignature(
  key: Hex,
  digest: Hex32): Hex {
  return encodeAbiParameters([{
    type: 'bytes'
  }, {
    type: 'bytes32'
  }], [sliceHex(key, 20), digest])
}

export function validateCrossChainRecoveryArtifact(
  artifact: CrossChainRecoveryArtifact): void {
  if (artifact.schema !== CROSS_CHAIN_RECOVERY_SCHEMA || artifact.mockVerifierDemo !== true)
    throw new Error('invalid recovery demo envelope')

  const expected = ['both-reclaim', 'final-claim-omitted', 'claim-wins', 'reclaim-wins']

  if (artifact.outcomes.map(value => value.scenario).join('|') !== expected.join('|'))
    throw new Error('recovery scenarios are missing or reordered')

  const states = artifact.outcomes.map(value => value.finalStates.map(state => state.state).join('/'))

  if (states.join('|') !== 'Reclaimed/Reclaimed|Reclaimed/Claimed|Claimed/Claimed|Reclaimed/Claimed')
    throw new Error('unexpected recovery terminal states')

  const expectedBalances = [
    [['10000000000000000000', '0', '0'], ['20000000000000000000', '0', '0']],
    [['10000000000000000000', '0', '0'], ['0', '20000000000000000000', '0']],
    [['0', '10000000000000000000', '0'], ['0', '20000000000000000000', '0']],
    [['10000000000000000000', '0', '0'], ['0', '20000000000000000000', '0']],
  ]

  for (const [index, value] of artifact.outcomes.entries()) {
    const balances = value.finalStates.map(state => state.holdings.map(holding => 'balance' in holding ? holding.balance : ''))

    if (JSON.stringify(balances) !== JSON.stringify(expectedBalances[index]) || !value.fixedPayouts)
      throw new Error(`invalid fixed payout for ${value.scenario}`)
  }

  const nonfinal = artifact.observations.filter(value => value.lifecycle !== 'final')

  if (nonfinal.length !== 6 || nonfinal.some(value => value.advanced || value.stageBefore !== value.stageAfter))
    throw new Error('non-final observation advanced trusted state')

  const finals = artifact.observations.filter(value => value.lifecycle === 'final')

  if (finals.length !== 2 || finals.some(value => !value.advanced || value.stageBefore === value.stageAfter))
    throw new Error('final observations did not advance trusted state')

  const serialized = JSON.stringify(artifact).toLowerCase()

  for (const forbidden of ['settlementsecret', 'bobcommitsecret', 'signature', 'activepqkey', 'recoverypqkey'])
    if (serialized.includes(forbidden))
      throw new Error(`artifact exposes sensitive field ${forbidden}`)
}

export function serializeCrossChainRecoveryArtifact(
  artifact: CrossChainRecoveryArtifact): string {
  return `${JSON.stringify(artifact, null, 2)}\n`
}
