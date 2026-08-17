import type {Address, Hex} from 'viem'
import type {ProtocolTerms, SideTerms} from './protocol.js'
import type {Asset, Hex32} from './types.js'
import type {AliceCommitStatus, WorkflowStage} from './workflows/trustedCrossChain.js'

export const CLIENT_STATE_SCHEMA = 'quip-swap-client-state.v1' as const

export interface PersistedAsset {
  readonly assetType: number
  readonly target: Address
  readonly id: string
  readonly amount: string
}

export interface PersistedSideTerms {
  readonly chainId: string
  readonly assets: readonly PersistedAsset[]
  readonly principal: Address
  readonly authorizationMode: number
  readonly principalKeyVersion: string
  readonly reclaimRecipient: Address
  readonly recipient: Address
  readonly commitmentDeadline: string
  readonly claimDeadline: string
  readonly reclaimRelease: string
  readonly commitLock: Hex32
  readonly delegationPolicy: number
  readonly delegate: Address
  readonly delegateKeyVersion: string
  readonly sideNonce: Hex32
}

export interface PersistedProtocolTerms {
  readonly timingPolicyId: Hex32
  readonly partySide: PersistedSideTerms
  readonly counterpartySide: PersistedSideTerms
}

export interface PersistedInclusion {
  readonly transactionHash: Hex
  readonly blockNumber: string
  readonly blockHash: Hex32
}

interface ClientStateBase {
  readonly schema: typeof CLIENT_STATE_SCHEMA
  readonly party: 'alice' | 'bob'
  readonly generation: number
  readonly sequence: number
  readonly tradeId: Hex32
  readonly terms: PersistedProtocolTerms
  readonly derived: {
    readonly gateContextId: Hex32
    readonly settlementLock: Hex32
    readonly partyCommitPayloadHash: Hex32
    readonly counterpartyCommitPayloadHash: Hex32
  }
  readonly selected: {
    readonly bobSubmitter: Address
    readonly finalClaimExecutors: readonly Address[]
    readonly finalClaimExecutor?: Address
  }
  readonly stage: WorkflowStage
  readonly aliceCommit: {
    readonly status: AliceCommitStatus
    readonly inclusion?: PersistedInclusion
  }
  readonly recovery: {
    readonly active: boolean
    readonly reason?: string
  }
}

export interface AliceClientState extends ClientStateBase {
  readonly party: 'alice'
  readonly progression: {
    readonly published: boolean
    readonly publishedBy?: Address
  }
}

export interface BobClientState extends ClientStateBase {
  readonly party: 'bob'
  readonly progression: {
    readonly observed: boolean
    readonly observedFrom?: Address
  }
}

export type ClientState = AliceClientState | BobClientState

const decimal = (value: bigint): string => value.toString(10)
const persistAsset = (asset: Asset): PersistedAsset => ({
  assetType: asset.assetType,
  target: asset.target,
  id: decimal(asset.id),
  amount: decimal(asset.amount),
})
const persistSide = (side: SideTerms): PersistedSideTerms => ({
  chainId: decimal(side.chainId),
  assets: side.assets.map(persistAsset),
  principal: side.principal,
  authorizationMode: side.authorizationMode,
  principalKeyVersion: decimal(side.principalKeyVersion),
  reclaimRecipient: side.reclaimRecipient,
  recipient: side.recipient,
  commitmentDeadline: decimal(side.commitmentDeadline),
  claimDeadline: decimal(side.claimDeadline),
  reclaimRelease: decimal(side.reclaimRelease),
  commitLock: side.commitLock,
  delegationPolicy: side.delegationPolicy,
  delegate: side.delegate,
  delegateKeyVersion: decimal(side.delegateKeyVersion),
  sideNonce: side.sideNonce,
})

export const persistProtocolTerms = (terms: ProtocolTerms): PersistedProtocolTerms => ({
  timingPolicyId: terms.timingPolicyId,
  partySide: persistSide(terms.partySide),
  counterpartySide: persistSide(terms.counterpartySide),
})

const restoreAsset = (asset: PersistedAsset): Asset => ({
  assetType: asset.assetType,
  target: asset.target,
  id: BigInt(asset.id),
  amount: BigInt(asset.amount),
}) as Asset
const restoreSide = (side: PersistedSideTerms): SideTerms => ({
  chainId: BigInt(side.chainId),
  assets: side.assets.map(restoreAsset),
  principal: side.principal,
  authorizationMode: side.authorizationMode,
  principalKeyVersion: BigInt(side.principalKeyVersion),
  reclaimRecipient: side.reclaimRecipient,
  recipient: side.recipient,
  commitmentDeadline: BigInt(side.commitmentDeadline),
  claimDeadline: BigInt(side.claimDeadline),
  reclaimRelease: BigInt(side.reclaimRelease),
  commitLock: side.commitLock,
  delegationPolicy: side.delegationPolicy,
  delegate: side.delegate,
  delegateKeyVersion: BigInt(side.delegateKeyVersion),
  sideNonce: side.sideNonce,
}) as SideTerms

export function restoreProtocolTerms(terms: PersistedProtocolTerms): ProtocolTerms {
  side(terms.partySide, 'terms.partySide')
  side(terms.counterpartySide, 'terms.counterpartySide')
  hex(terms.timingPolicyId, 32, 'terms.timingPolicyId')
  return {
    timingPolicyId: terms.timingPolicyId,
    partySide: restoreSide(terms.partySide),
    counterpartySide: restoreSide(terms.counterpartySide),
  }
}

export function serializeClientState(state: ClientState): string {
  validateClientState(state)
  return `${JSON.stringify(state, null, 2)}\n`
}

export function parseClientState(serialized: string): ClientState {
  let value: unknown
  try {
    value = JSON.parse(serialized)
  } catch {
    throw new Error('client state is not valid JSON')
  }
  validateClientState(value)
  return value
}

export function clientStatesEqual(left: ClientState, right: ClientState): boolean {
  return serializeClientState(left) === serializeClientState(right)
}

function record(value: unknown, label: string): asserts value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${label} must be an object`)
}
function integer(value: unknown, label: string): asserts value is number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) throw new Error(`${label} must be a nonnegative integer`)
}
function decimalString(value: unknown, label: string): asserts value is string {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) throw new Error(`${label} must be decimal`)
}
function address(value: unknown, label: string): asserts value is Address {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value)) throw new Error(`${label} must be an address`)
}
function hex(value: unknown, bytes: number | undefined, label: string): asserts value is Hex {
  const length = bytes === undefined ? '+' : `{${bytes * 2}}`
  if (typeof value !== 'string' || !new RegExp(`^0x[0-9a-fA-F]${length}$`).test(value)) {
    throw new Error(`${label} must be ${bytes === undefined ? 'hex' : `${bytes}-byte hex`}`)
  }
}
function side(value: unknown, label: string): void {
  record(value, label)
  decimalString(value['chainId'], `${label}.chainId`)
  if (!Array.isArray(value['assets']) || value['assets'].length === 0) throw new Error(`${label}.assets must be nonempty`)
  for (const [index, candidate] of value['assets'].entries()) {
    record(candidate, `${label}.assets[${index}]`)
    integer(candidate['assetType'], `${label}.assets[${index}].assetType`)
    address(candidate['target'], `${label}.assets[${index}].target`)
    decimalString(candidate['id'], `${label}.assets[${index}].id`)
    decimalString(candidate['amount'], `${label}.assets[${index}].amount`)
  }
  for (const field of ['principalKeyVersion', 'commitmentDeadline', 'claimDeadline', 'reclaimRelease', 'delegateKeyVersion']) {
    decimalString(value[field], `${label}.${field}`)
  }
  for (const field of ['principal', 'reclaimRecipient', 'recipient', 'delegate']) address(value[field], `${label}.${field}`)
  integer(value['authorizationMode'], `${label}.authorizationMode`)
  integer(value['delegationPolicy'], `${label}.delegationPolicy`)
  hex(value['commitLock'], 32, `${label}.commitLock`)
  hex(value['sideNonce'], 32, `${label}.sideNonce`)
}

export function validateClientState(value: unknown): asserts value is ClientState {
  record(value, 'client state')
  if (value['schema'] !== CLIENT_STATE_SCHEMA) throw new Error('unsupported client state schema')
  if (value['party'] !== 'alice' && value['party'] !== 'bob') throw new Error('invalid client party')
  integer(value['generation'], 'generation')
  integer(value['sequence'], 'sequence')
  hex(value['tradeId'], 32, 'tradeId')
  record(value['terms'], 'terms')
  hex(value['terms']['timingPolicyId'], 32, 'terms.timingPolicyId')
  side(value['terms']['partySide'], 'terms.partySide')
  side(value['terms']['counterpartySide'], 'terms.counterpartySide')
  record(value['derived'], 'derived')
  for (const field of ['gateContextId', 'settlementLock', 'partyCommitPayloadHash', 'counterpartyCommitPayloadHash']) {
    hex(value['derived'][field], 32, `derived.${field}`)
  }
  record(value['selected'], 'selected')
  address(value['selected']['bobSubmitter'], 'selected.bobSubmitter')
  if (!Array.isArray(value['selected']['finalClaimExecutors'])) throw new Error('finalClaimExecutors must be an array')
  for (const executor of value['selected']['finalClaimExecutors']) address(executor, 'finalClaimExecutor')
  if (value['selected']['finalClaimExecutor'] !== undefined) {
    address(value['selected']['finalClaimExecutor'], 'selected.finalClaimExecutor')
    if (!(value['selected']['finalClaimExecutors'] as unknown[]).includes(value['selected']['finalClaimExecutor'])) {
      throw new Error('selected final-claim executor is not configured')
    }
  }
  const stages = ['prepared', 'alice-commit', 'bob-enabled', 'bob-commit-pending', 'bob-committed', 'reveal-final', 'final-claim', 'complete', 'recovery']
  if (!stages.includes(value['stage'] as string)) throw new Error('invalid workflow stage')
  record(value['aliceCommit'], 'aliceCommit')
  if (!['not-submitted', 'pending', 'included-non-final', 'final'].includes(value['aliceCommit']['status'] as string)) {
    throw new Error('invalid Alice commit status')
  }
  if (value['aliceCommit']['inclusion'] !== undefined) {
    record(value['aliceCommit']['inclusion'], 'aliceCommit.inclusion')
    hex(value['aliceCommit']['inclusion']['transactionHash'], undefined, 'inclusion.transactionHash')
    decimalString(value['aliceCommit']['inclusion']['blockNumber'], 'inclusion.blockNumber')
    hex(value['aliceCommit']['inclusion']['blockHash'], 32, 'inclusion.blockHash')
  }
  record(value['recovery'], 'recovery')
  if (typeof value['recovery']['active'] !== 'boolean') throw new Error('recovery.active must be boolean')
  if (value['recovery']['reason'] !== undefined && typeof value['recovery']['reason'] !== 'string') {
    throw new Error('recovery.reason must be a string')
  }
  record(value['progression'], 'progression')
  if (value['party'] === 'alice') {
    if (typeof value['progression']['published'] !== 'boolean' || value['progression']['observed'] !== undefined) {
      throw new Error('invalid Alice progression state')
    }
    if (value['progression']['publishedBy'] !== undefined) address(value['progression']['publishedBy'], 'publishedBy')
  } else {
    if (typeof value['progression']['observed'] !== 'boolean' || value['progression']['published'] !== undefined) {
      throw new Error('invalid Bob progression state')
    }
    if (value['progression']['observedFrom'] !== undefined) address(value['progression']['observedFrom'], 'observedFrom')
  }
}
