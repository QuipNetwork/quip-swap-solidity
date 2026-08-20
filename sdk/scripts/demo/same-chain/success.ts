import {
  concatHex,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  sliceHex,
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
  readonly principalBalance: string
  readonly recipientBalance: string
  readonly wrapperBalance: string
  readonly allowance: string
  readonly reserved: string
}

export interface SameChainSnapshot {
  readonly state: 'Unused' | 'PartyCommitted' | 'BothCommitted' | 'Claimed' | 'Reclaimed'
  readonly assets: readonly [SameChainAssetPosition, SameChainAssetPosition]
}

export interface SameChainActionTrace {
  readonly action: 'alice-commit' | 'bob-commit' | 'permissionless-claim'
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
}

export interface SameChainSuccessTrace {
  readonly settlementSecret: Hex32
  readonly actions: readonly [SameChainActionTrace, SameChainActionTrace, SameChainActionTrace]
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

  onProgress?.('Submitting one permissionless atomic claim')
  const claimant = createProtocolClient({
    addresses,
    publicClient: chain.publicClient,
    walletClient: chain.charlie.walletClient,
  })
  const claimHash = await claimant.claimSameChain(terms, lock, SAME_CHAIN_SETTLEMENT_SECRET)
  const claimReceipt = await successfulReceipt(chain, claimHash)
  const claimEvents = decodeProtocolEvents(claimReceipt.logs, addresses)
  const finalSnapshot = await readSameChainSnapshot(chain, addresses.sameChainWrapper, terms, lock)
  assertFinalPayouts(finalSnapshot, terms)
  const claimTrace = trace(
    'permissionless-claim',
    chain.charlie.address,
    claimReceipt,
    afterBob,
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
    actions: [aliceTrace, bobTrace, claimTrace],
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
  const hash = await client.registerAndCommit(
    registration,
    '0x',
    pqSignature(activeKey, keyPossessionDigest(digest, KeyRole.Active, activeKey)),
    pqSignature(recoveryKey, keyPossessionDigest(digest, KeyRole.Recovery, recoveryKey)),
    sliceHex(call, 4),
  )
  const receipt = await successfulReceipt(chain, hash)
  const events = decodeProtocolEvents(receipt.logs, addresses)
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
  const position = async (
    role: SameChainAssetPosition['role'],
    side: ProtocolTerms['partySide'],
  ): Promise<SameChainAssetPosition> => {
    const asset = side.assets[0]
    if (asset === undefined) throw new Error(`${role} has no asset`)
    const [principalBalance, recipientBalance, wrapperBalance, allowance, reserved] = await Promise.all([
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
        args: [wrapper],
      }),
      chain.publicClient.readContract({
        address: asset.target,
        abi: erc20MockAbi,
        functionName: 'allowance',
        args: [side.principal, wrapper],
      }),
      chain.publicClient.readContract({
        address: wrapper,
        abi: sameChainWrapperAbi,
        functionName: 'reserved',
        args: [asset],
      }),
    ])
    return {
      role,
      principal: side.principal,
      recipient: side.recipient,
      token: asset.target,
      principalBalance: principalBalance.toString(),
      recipientBalance: recipientBalance.toString(),
      wrapperBalance: wrapperBalance.toString(),
      allowance: allowance.toString(),
      reserved: reserved.toString(),
    }
  }
  const state = await chain.publicClient.readContract({
    address: wrapper,
    abi: sameChainWrapperAbi,
    functionName: 'state',
    args: [terms, lock],
  })
  const stateName = SameChainState[state]
  if (
    stateName !== 'Unused'
    && stateName !== 'PartyCommitted'
    && stateName !== 'BothCommitted'
    && stateName !== 'Claimed'
    && stateName !== 'Reclaimed'
  ) {
    throw new Error(`unknown same-chain state: ${state}`)
  }
  return {
    state: stateName,
    assets: await Promise.all([
      position('alice-asset', terms.partySide),
      position('bob-asset', terms.counterpartySide),
    ]),
  }
}

function assertCommit(
  result: LazyCommitResult,
  after: SameChainSnapshot,
  expectedState: SameChainSnapshot['state'],
  principal: Address,
): void {
  if (after.state !== expectedState) throw new Error(`expected ${expectedState}, got ${after.state}`)
  const nonce = result.events.find(event =>
    event.source === 'sameChainWrapper'
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
  if (nonce === undefined || registered === undefined || committed === undefined) {
    throw new Error('commit receipt lacks registration, nonce-consumption, or commit evidence')
  }
}

function assertFinalPayouts(snapshotValue: SameChainSnapshot, terms: ProtocolTerms): void {
  if (snapshotValue.state !== 'Claimed') throw new Error('same-chain claim did not reach Claimed')
  const expected = [terms.partySide.assets[0]!.amount, terms.counterpartySide.assets[0]!.amount]
  snapshotValue.assets.forEach((asset, index) => {
    if (
      asset.principalBalance !== '0'
      || asset.recipientBalance !== expected[index]!.toString()
      || asset.wrapperBalance !== '0'
      || asset.reserved !== '0'
    ) {
      throw new Error(`${asset.role} final payout or reserve mismatch`)
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
): SameChainActionTrace {
  return {
    action,
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
  const hash = await client.authorizeDirectCommit(request, signature)
  const receipt = await successfulReceipt(chain, hash)
  const events = decodeProtocolEvents(receipt.logs, addresses)
  const nonceKey = keccak256(encodeAuthorizationNonceKey(
    BigInt(chain.chainId),
    addresses.directAuthorization,
    side.principal,
    side.principalKeyVersion,
    actionNonce,
  ))
  return {receipt, events, nonceKey}
}
