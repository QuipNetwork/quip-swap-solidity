import {
  concatHex,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  sliceHex,
  zeroAddress,
} from 'viem'
import type {Address, Hash, Hex, TransactionReceipt} from 'viem'
import {
  ExpectedSourceState,
  KeyRole,
  SameChainState,
  commitPayloadHash,
  createProtocolClient,
  decodeProtocolEvents,
  encodeAuthorizationNonceKey,
  keyPossessionDigest,
  registrationDigest,
} from '../../../src/index.js'
import type {
  CommitAuthorizationRequest,
  Hex32,
  InitialRegistration,
  ProtocolTerms,
} from '../../../src/index.js'
import {directAuthorizationAbi} from '../../../src/generated/directAuthorizationAbi.js'
import {sameChainWrapperAbi} from '../../../src/generated/sameChainWrapperAbi.js'
import type {ProtocolEvent} from '../../../src/protocolEvents.js'
import type {ChainContext} from '../../../test/helpers/chain.js'
import {erc20MockAbi} from '../../../test/helpers/mockAbis.js'
import type {DemoChainDeployment} from '../shared/environment.js'

const ZERO32 = `0x${'00'.repeat(32)}` as Hex32
const fixed = (value: number): Hex32 => `0x${value.toString(16).padStart(64, '0')}` as Hex32
export const SAME_CHAIN_SETTLEMENT_SECRET = fixed(1)

export interface SameChainAssetPosition {
  readonly role: 'alice-asset' | 'bob-asset'
  readonly principal: Address
  readonly recipient: Address
  readonly token: Address
  readonly htlc: Address
  readonly htlcDeployed: boolean
  readonly htlcFunded: boolean
  readonly htlcReleased: boolean
  readonly nextAssetIndex: string
  readonly payoutRecipient: Address
  readonly principalBalance: string
  readonly recipientBalance: string
  readonly htlcBalance: string
  readonly allowance: string
}

export interface SameChainSnapshot {
  readonly state:
    | 'Unused'
    | 'PartyCommitted'
    | 'BothCommitted'
    | 'ClaimPending'
    | 'ReclaimPending'
    | 'Claimed'
    | 'Reclaimed'
  readonly expectedSides: number
  readonly completedSides: number
  readonly assets: readonly [SameChainAssetPosition, SameChainAssetPosition]
}

export interface SameChainActionTrace {
  readonly action:
    | 'alice-commit'
    | 'bob-commit'
    | 'claim-selection'
    | 'party-release'
    | 'counterparty-release-failed'
    | 'counterparty-release-retry'
  readonly receiptStatus: 'success' | 'reverted'
  readonly caller: Address
  readonly transactionHash: Hash
  readonly blockNumber: string
  readonly stateBefore: SameChainSnapshot['state']
  readonly stateAfter: SameChainSnapshot['state']
  readonly events: readonly string[]
  readonly authorizationNonceKey: Hex32 | null
  readonly authorizationNonceConsumed: boolean | null
  readonly progressionSecret: Hex32 | null
  readonly custodyAfter: SameChainSnapshot['assets']
  readonly expectedSides: number
  readonly completedSides: number
  readonly failureReason: 'insufficient-gas' | null
}

export interface SameChainSuccessTrace {
  readonly settlementSecret: Hex32
  readonly actions: readonly [
    SameChainActionTrace,
    SameChainActionTrace,
    SameChainActionTrace,
    SameChainActionTrace,
    SameChainActionTrace,
    SameChainActionTrace,
  ]
  readonly finalSnapshot: SameChainSnapshot
  readonly payoutsFixedByTerms: true
  readonly identities: {
    readonly alice: {readonly active: true; readonly activeKeyVersion: '1'; readonly recoveryKeyVersion: '1'}
    readonly bob: {readonly active: true; readonly activeKeyVersion: '1'; readonly recoveryKeyVersion: '1'}
  }
}

interface LazyCommitResult {
  readonly receipt: TransactionReceipt
  readonly events: readonly ProtocolEvent[]
  readonly nonceKey: Hex32
}

export async function runSameChainSuccess(
  chain: ChainContext,
  deployment: Omit<DemoChainDeployment, 'funding'>,
  terms: ProtocolTerms,
  lock: Hex32,
  onProgress?: (message: string) => void,
): Promise<SameChainSuccessTrace> {
  const addresses = deployment.addresses
  const initial = await readSameChainSnapshot(chain, addresses.sameChainWrapper, terms, lock)
  if (initial.state !== 'Unused') throw new Error('same-chain success path did not start Unused')

  onProgress?.("Submitting Alice's lazy-registration party commit")
  const aliceCommit = await submitSameChainLazyCommit({
    chain,
    deployment,
    terms,
    lock,
    party: true,
    actionNonce: fixed(5),
    operationNonce: fixed(201),
    activeSeed: fixed(101),
    recoverySeed: fixed(102),
  })
  const afterAlice = await readSameChainSnapshot(chain, addresses.sameChainWrapper, terms, lock)
  assertCommit(aliceCommit, afterAlice, 'PartyCommitted', terms.partySide.principal)
  const aliceTrace = trace(
    'alice-commit',
    chain.alice.address,
    aliceCommit.receipt,
    initial,
    afterAlice,
    aliceCommit.events,
    aliceCommit.nonceKey,
  )

  onProgress?.("Submitting Bob's lazy-registration counterparty commit")
  const bobCommit = await submitSameChainLazyCommit({
    chain,
    deployment,
    terms,
    lock,
    party: false,
    actionNonce: fixed(6),
    operationNonce: fixed(202),
    activeSeed: fixed(103),
    recoverySeed: fixed(104),
  })
  const afterBob = await readSameChainSnapshot(chain, addresses.sameChainWrapper, terms, lock)
  assertCommit(bobCommit, afterBob, 'BothCommitted', terms.counterpartySide.principal)
  const bobTrace = trace(
    'bob-commit',
    chain.bob.address,
    bobCommit.receipt,
    afterAlice,
    afterBob,
    bobCommit.events,
    bobCommit.nonceKey,
  )

  onProgress?.('Selecting the permissionless claim outcome without moving assets')
  const claimant = createProtocolClient({
    addresses,
    publicClient: chain.publicClient,
    walletClient: chain.charlie.walletClient,
  })
  const selectionReceipt = await successfulReceipt(
    chain,
    await claimant.selectSameChainClaim(terms, lock, SAME_CHAIN_SETTLEMENT_SECRET),
  )
  const selected = await readSameChainSnapshot(chain, addresses.sameChainWrapper, terms, lock)
  if (selected.state !== 'ClaimPending' || selected.expectedSides !== 3 || selected.completedSides !== 0) {
    throw new Error('claim selection did not establish an empty two-side completion bitmap')
  }
  const selectionTrace = trace(
    'claim-selection',
    chain.charlie.address,
    selectionReceipt,
    afterBob,
    selected,
    decodeProtocolEvents(selectionReceipt.logs, addresses),
    null,
  )

  onProgress?.('Releasing the party HTLC while keeping the claim pending')
  const partyHTLC = await claimant.getSameChainHTLC(terms, true, lock)
  const counterpartyHTLC = await claimant.getSameChainHTLC(terms, false, lock)
  const partyReceipt = await successfulReceipt(
    chain,
    await claimant.executeSameChainSettlement(terms, lock, true, BigInt(terms.partySide.assets.length)),
  )
  const afterParty = await readSameChainSnapshot(chain, addresses.sameChainWrapper, terms, lock)
  if (
    afterParty.state !== 'ClaimPending'
    || afterParty.expectedSides !== 3
    || afterParty.completedSides !== 1
    || !afterParty.assets[0].htlcReleased
    || afterParty.assets[1].htlcReleased
  ) {
    throw new Error('party release did not preserve the pending claim and mark only the party bit')
  }
  const partyTrace = trace(
    'party-release',
    chain.charlie.address,
    partyReceipt,
    selected,
    afterParty,
    decodeProtocolEvents(partyReceipt.logs, addresses, [], [partyHTLC]),
    null,
  )

  onProgress?.('Submitting an intentionally under-gassed counterparty release')
  const beforeFailure = await readSameChainSnapshot(chain, addresses.sameChainWrapper, terms, lock)
  const failedHash = await chain.charlie.walletClient.writeContract({
    address: addresses.sameChainWrapper,
    abi: sameChainWrapperAbi,
    functionName: 'executeSettlement',
    args: [terms, lock, false, BigInt(terms.counterpartySide.assets.length)],
    account: chain.charlie.account,
    chain: chain.publicClient.chain ?? null,
    gas: 80_000n,
  })
  const failedReceipt = await chain.publicClient.waitForTransactionReceipt({hash: failedHash})
  if (failedReceipt.status !== 'reverted') throw new Error('counterparty failure transaction unexpectedly succeeded')
  const afterFailure = await readSameChainSnapshot(chain, addresses.sameChainWrapper, terms, lock)
  if (JSON.stringify(beforeFailure) !== JSON.stringify(afterFailure)) {
    throw new Error('failed counterparty release changed settlement progress or custody')
  }
  const failedTrace = trace(
    'counterparty-release-failed',
    chain.charlie.address,
    failedReceipt,
    beforeFailure,
    afterFailure,
    decodeProtocolEvents(failedReceipt.logs, addresses, [], [counterpartyHTLC]),
    null,
    'insufficient-gas',
  )

  onProgress?.('Retrying the counterparty release with normal gas estimation')
  const claimHash = await claimant.executeSameChainSettlement(
    terms,
    lock,
    false,
    BigInt(terms.counterpartySide.assets.length),
  )
  const claimReceipt = await successfulReceipt(chain, claimHash)
  const claimEvents = decodeProtocolEvents(claimReceipt.logs, addresses, [], [counterpartyHTLC])
  const finalSnapshot = await readSameChainSnapshot(chain, addresses.sameChainWrapper, terms, lock)
  assertFinalPayouts(finalSnapshot, terms)
  const claimTrace = trace(
    'counterparty-release-retry',
    chain.charlie.address,
    claimReceipt,
    afterFailure,
    finalSnapshot,
    claimEvents,
    null,
  )

  const [aliceIdentity, bobIdentity] = await Promise.all([
    chain.publicClient.readContract({
      address: addresses.directAuthorization,
      abi: directAuthorizationAbi,
      functionName: 'identityOf',
      args: [terms.partySide.principal],
    }),
    chain.publicClient.readContract({
      address: addresses.directAuthorization,
      abi: directAuthorizationAbi,
      functionName: 'identityOf',
      args: [terms.counterpartySide.principal],
    }),
  ])
  if (
    !aliceIdentity.active
    || aliceIdentity.activeKeyVersion !== 1n
    || aliceIdentity.recoveryKeyVersion !== 1n
    || !bobIdentity.active
    || bobIdentity.activeKeyVersion !== 1n
    || bobIdentity.recoveryKeyVersion !== 1n
  ) {
    throw new Error('lazy direct registration did not activate both identities')
  }

  return {
    settlementSecret: SAME_CHAIN_SETTLEMENT_SECRET,
    actions: [aliceTrace, bobTrace, selectionTrace, partyTrace, failedTrace, claimTrace],
    finalSnapshot,
    payoutsFixedByTerms: true,
    identities: {
      alice: {active: true, activeKeyVersion: '1', recoveryKeyVersion: '1'},
      bob: {active: true, activeKeyVersion: '1', recoveryKeyVersion: '1'},
    },
  }
}

export async function submitSameChainLazyCommit(input: {
  readonly chain: ChainContext
  readonly deployment: Omit<DemoChainDeployment, 'funding'>
  readonly terms: ProtocolTerms
  readonly lock: Hex32
  readonly party: boolean
  readonly actionNonce: Hex32
  readonly operationNonce: Hex32
  readonly activeSeed: Hex32
  readonly recoverySeed: Hex32
  readonly bobCommitSecret?: Hex32
  readonly expiry?: bigint
}): Promise<LazyCommitResult> {
  const {chain, deployment, terms, lock, party, actionNonce, operationNonce} = input
  const addresses = deployment.addresses
  const side = party ? terms.partySide : terms.counterpartySide
  const actor = party ? chain.alice : chain.bob
  const expectedSourceState = party ? ExpectedSourceState.Unused : ExpectedSourceState.PartyCommitted
  const expiry = input.expiry ?? side.commitmentDeadline
  const payloadHash = commitPayloadHash({
    terms,
    party,
    authorizationVerifier: addresses.directAuthorization,
    swapAddress: addresses.sameChainWrapper,
    lock,
    expectedSourceState,
    actionNonce,
    expiry,
  })
  const request: CommitAuthorizationRequest = {
    receiver: addresses.sameChainWrapper,
    terms,
    party,
    lock,
    actionNonce,
    bobCommitSecret: input.bobCommitSecret ?? ZERO32,
    expiry,
    commitData: '0x',
  }
  const activeKey = prototypePQKey(deployment.trustedVerifier, input.activeSeed)
  const recoveryKey = prototypePQKey(deployment.trustedVerifier, input.recoverySeed)
  const registration: InitialRegistration = {
    eoa: side.principal,
    activePQKey: activeKey,
    recoveryPQKey: recoveryKey,
    commitTarget: addresses.directAuthorization,
    commitPayloadHash: payloadHash,
    operationNonce,
    expiry,
  }
  const digest = registrationDigest(BigInt(chain.chainId), addresses.directAuthorization, registration)
  const call = encodeFunctionData({
    abi: directAuthorizationAbi,
    functionName: 'authorizeCommit',
    args: [request, pqSignature(activeKey, payloadHash)],
  })
  const client = createProtocolClient({
    addresses,
    publicClient: chain.publicClient,
    walletClient: actor.walletClient,
  })
  const htlc = await client.predictSameChainHTLC(terms, party, lock)
  const hash = await client.registerAndCommit(
    registration,
    '0x',
    pqSignature(activeKey, keyPossessionDigest(digest, KeyRole.Active, activeKey)),
    pqSignature(recoveryKey, keyPossessionDigest(digest, KeyRole.Recovery, recoveryKey)),
    sliceHex(call, 4),
  )
  const receipt = await successfulReceipt(chain, hash)
  const events = decodeProtocolEvents(receipt.logs, addresses, [], [htlc])
  const nonceKey = keccak256(encodeAuthorizationNonceKey(
    BigInt(chain.chainId),
    addresses.directAuthorization,
    side.principal,
    side.principalKeyVersion,
    actionNonce,
  ))
  return {receipt, events, nonceKey}
}

function prototypePQKey(verifier: Address, seed: Hex32): Hex {
  return concatHex([verifier, seed])
}

function pqSignature(key: Hex, digest: Hex32): Hex {
  return encodeAbiParameters([{type: 'bytes'}, {type: 'bytes32'}], [sliceHex(key, 20), digest])
}

async function successfulReceipt(chain: ChainContext, hash: Hash): Promise<TransactionReceipt> {
  const receipt = await chain.publicClient.waitForTransactionReceipt({hash})
  if (receipt.status !== 'success') throw new Error(`same-chain transaction reverted: ${hash}`)
  return receipt
}

export async function readSameChainSnapshot(
  chain: ChainContext,
  wrapper: Address,
  terms: ProtocolTerms,
  lock: Hex32,
): Promise<SameChainSnapshot> {
  const client = createProtocolClient({
    addresses: {
      assetSupportRegistry: zeroAddress,
      directAuthorization: zeroAddress,
      crossChainWrapper: zeroAddress,
      sameChainWrapper: wrapper,
    },
    publicClient: chain.publicClient,
  })
  const position = async (
    role: SameChainAssetPosition['role'],
    side: ProtocolTerms['partySide'],
    party: boolean,
  ): Promise<SameChainAssetPosition> => {
    const asset = side.assets[0]
    if (asset === undefined) throw new Error(`${role} has no asset`)
    const deployedHTLC = await client.getSameChainHTLC(terms, party, lock)
    const htlcDeployed = deployedHTLC !== zeroAddress
    const htlc = htlcDeployed
      ? deployedHTLC
      : await client.predictSameChainHTLC(terms, party, lock)
    const htlcState = htlcDeployed ? await client.getHTLCState(htlc) : undefined
    const [principalBalance, recipientBalance, htlcBalance, allowance] = await Promise.all([
      chain.publicClient.readContract({
        address: asset.target,
        abi: erc20MockAbi,
        functionName: 'balanceOf',
        args: [side.principal],
      }),
      chain.publicClient.readContract({
        address: asset.target,
        abi: erc20MockAbi,
        functionName: 'balanceOf',
        args: [side.recipient],
      }),
      chain.publicClient.readContract({
        address: asset.target,
        abi: erc20MockAbi,
        functionName: 'balanceOf',
        args: [htlc],
      }),
      chain.publicClient.readContract({
        address: asset.target,
        abi: erc20MockAbi,
        functionName: 'allowance',
        args: [side.principal, wrapper],
      }),
    ])
    return {
      role,
      principal: side.principal,
      recipient: side.recipient,
      token: asset.target,
      htlc,
      htlcDeployed,
      htlcFunded: htlcState?.funded ?? false,
      htlcReleased: htlcState?.released ?? false,
      nextAssetIndex: (htlcState?.nextAssetIndex ?? 0n).toString(),
      payoutRecipient: htlcState?.payoutRecipient ?? zeroAddress,
      principalBalance: principalBalance.toString(),
      recipientBalance: recipientBalance.toString(),
      htlcBalance: htlcBalance.toString(),
      allowance: allowance.toString(),
    }
  }
  const [state, progress] = await Promise.all([
    client.getSameChainState(terms, lock),
    client.getSameChainSettlementProgress(terms, lock),
  ])
  const stateName = SameChainState[state]
  if (
    stateName !== 'Unused'
    && stateName !== 'PartyCommitted'
    && stateName !== 'BothCommitted'
    && stateName !== 'ClaimPending'
    && stateName !== 'ReclaimPending'
    && stateName !== 'Claimed'
    && stateName !== 'Reclaimed'
  ) {
    throw new Error(`unknown same-chain state: ${state}`)
  }
  const snapshot: SameChainSnapshot = {
    state: stateName,
    expectedSides: progress.expectedSides,
    completedSides: progress.completedSides,
    assets: await Promise.all([
      position('alice-asset', terms.partySide, true),
      position('bob-asset', terms.counterpartySide, false),
    ]),
  }
  validateHTLCLifecycle(snapshot)
  return snapshot
}

function assertCommit(
  result: LazyCommitResult,
  after: SameChainSnapshot,
  expectedState: SameChainSnapshot['state'],
  principal: Address,
): void {
  if (after.state !== expectedState) throw new Error(`expected ${expectedState}, got ${after.state}`)
  const nonce = result.events.find(event =>
    event.source === 'directAuthorization'
    && event.eventName === 'AuthorizationNonceConsumed'
    && typeof event.args === 'object'
    && event.args !== null
    && (event.args as {readonly nonceKey?: unknown}).nonceKey === result.nonceKey
  )
  const registered = result.events.find(event =>
    event.source === 'directAuthorization'
    && event.eventName === 'IdentityRegistered'
    && typeof event.args === 'object'
    && event.args !== null
    && (event.args as {readonly eoa?: unknown}).eoa === principal
  )
  const committed = result.events.find(event =>
    event.source === 'sameChainWrapper'
    && event.eventName === 'Committed'
  )
  const created = result.events.find(event =>
    event.source === 'sameChainWrapper'
    && event.eventName === 'HTLCCreated'
  )
  const funded = result.events.find(event =>
    event.source === 'swapHTLC'
    && event.eventName === 'Funded'
  )
  if (nonce === undefined || registered === undefined || committed === undefined || created === undefined || funded === undefined) {
    throw new Error('commit receipt lacks registration, nonce-consumption, or HTLC funding evidence')
  }
}

function validateHTLCLifecycle(snapshot: SameChainSnapshot): void {
  const [party, counterparty] = snapshot.assets
  const expected = snapshot.state === 'Unused'
    ? [[false, false, false], [false, false, false]]
    : snapshot.state === 'PartyCommitted'
      ? [[true, true, false], [false, false, false]]
      : snapshot.state === 'BothCommitted' || snapshot.state === 'ClaimPending' || snapshot.state === 'ReclaimPending'
        ? [[true, true, false], [true, true, false]]
        : [[true, true, true], [true, true, true]]
  if (snapshot.state === 'ClaimPending' || snapshot.state === 'ReclaimPending') {
    expected[0]![2] = (snapshot.completedSides & 1) !== 0
    expected[1]![2] = (snapshot.completedSides & 2) !== 0
  }
  if (snapshot.state === 'Reclaimed' && snapshot.expectedSides === 1) {
    expected[1] = [false, false, false]
  }
  for (const [index, asset] of [party, counterparty].entries()) {
    const [deployed, funded, released] = expected[index]!
    if (asset.htlcDeployed !== deployed || asset.htlcFunded !== funded || asset.htlcReleased !== released) {
      throw new Error(`${asset.role} HTLC lifecycle disagrees with ${snapshot.state}`)
    }
  }
}

function assertFinalPayouts(snapshotValue: SameChainSnapshot, terms: ProtocolTerms): void {
  if (snapshotValue.state !== 'Claimed') throw new Error('same-chain claim did not reach Claimed')
  const expected = [terms.partySide.assets[0]!.amount, terms.counterpartySide.assets[0]!.amount]
  snapshotValue.assets.forEach((asset, index) => {
    if (
      asset.principalBalance !== '0'
      || asset.recipientBalance !== expected[index]!.toString()
      || asset.htlcBalance !== '0'
      || !asset.htlcDeployed
      || !asset.htlcFunded
      || !asset.htlcReleased
    ) {
      throw new Error(`${asset.role} final payout or HTLC lifecycle mismatch`)
    }
  })
}

function trace(
  action: SameChainActionTrace['action'],
  caller: Address,
  receipt: TransactionReceipt,
  before: SameChainSnapshot,
  after: SameChainSnapshot,
  events: readonly ProtocolEvent[],
  nonceKey: Hex32 | null,
  failureReason: SameChainActionTrace['failureReason'] = null,
): SameChainActionTrace {
  return {
    action,
    receiptStatus: receipt.status,
    caller,
    transactionHash: receipt.transactionHash,
    blockNumber: receipt.blockNumber.toString(),
    stateBefore: before.state,
    stateAfter: after.state,
    events: events.map(event => `${event.source}.${event.eventName}`),
    authorizationNonceKey: nonceKey,
    authorizationNonceConsumed: nonceKey === null ? null : events.some(event =>
      event.eventName === 'AuthorizationNonceConsumed'
      && typeof event.args === 'object'
      && event.args !== null
      && (event.args as {readonly nonceKey?: unknown}).nonceKey === nonceKey
    ),
    progressionSecret: nonceKey === null ? null : ZERO32,
    custodyAfter: after.assets,
    expectedSides: after.expectedSides,
    completedSides: after.completedSides,
    failureReason,
  }
}

export async function submitSameChainDirectCommit(input: {
  readonly chain: ChainContext
  readonly deployment: Omit<DemoChainDeployment, 'funding'>
  readonly terms: ProtocolTerms
  readonly lock: Hex32
  readonly party: boolean
  readonly actionNonce: Hex32
  readonly activeSeed: Hex32
  readonly bobCommitSecret?: Hex32
  readonly expiry?: bigint
  readonly invalidSignature?: boolean
}): Promise<LazyCommitResult> {
  const {chain, deployment, terms, lock, party, actionNonce} = input
  const addresses = deployment.addresses
  const side = party ? terms.partySide : terms.counterpartySide
  const actor = party ? chain.alice : chain.bob
  const expectedSourceState = party ? ExpectedSourceState.Unused : ExpectedSourceState.PartyCommitted
  const expiry = input.expiry ?? side.commitmentDeadline
  const payloadHash = commitPayloadHash({
    terms,
    party,
    authorizationVerifier: addresses.directAuthorization,
    swapAddress: addresses.sameChainWrapper,
    lock,
    expectedSourceState,
    actionNonce,
    expiry,
  })
  const request: CommitAuthorizationRequest = {
    receiver: addresses.sameChainWrapper,
    terms,
    party,
    lock,
    actionNonce,
    bobCommitSecret: input.bobCommitSecret ?? ZERO32,
    expiry,
    commitData: '0x',
  }
  const activeKey = prototypePQKey(deployment.trustedVerifier, input.activeSeed)
  const signature = input.invalidSignature === true
    ? pqSignature(activeKey, fixed(9_999))
    : pqSignature(activeKey, payloadHash)
  const client = createProtocolClient({
    addresses,
    publicClient: chain.publicClient,
    walletClient: actor.walletClient,
  })
  const htlc = await client.predictSameChainHTLC(terms, party, lock)
  const hash = await client.authorizeDirectCommit(request, signature)
  const receipt = await successfulReceipt(chain, hash)
  const events = decodeProtocolEvents(receipt.logs, addresses, [], [htlc])
  const nonceKey = keccak256(encodeAuthorizationNonceKey(
    BigInt(chain.chainId),
    addresses.directAuthorization,
    side.principal,
    side.principalKeyVersion,
    actionNonce,
  ))
  return {receipt, events, nonceKey}
}
