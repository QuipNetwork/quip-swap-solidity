import {zeroAddress} from 'viem'
import type {Address, Hash, Log, PublicClient, TransactionReceipt} from 'viem'
import {CrossChainLegState, createProtocolClient, decodeProtocolEvents} from '../../../src/index.js'
import type {Hex32, ProtocolAddresses, ProtocolEvent, ProtocolTerms} from '../../../src/index.js'

export const SETTLEMENT_TRACE_SCHEMA = 'quip-swap-settlement-trace.v1' as const

export type SettlementAction = 'alice-commit' | 'bob-commit' | 'revealing-claim' | 'final-claim' | 'reclaim'
export type ProgressionGateOutcome = 'bob-secret-published' | 'bob-secret-accepted' | 'not-applicable'

export type TrackedHolding =
  | {readonly assetType: 'native'; readonly account: Address}
  | {readonly assetType: 'erc20'; readonly token: Address; readonly account: Address}
  | {readonly assetType: 'erc721'; readonly token: Address; readonly tokenId: bigint}
  | {readonly assetType: 'erc1155'; readonly token: Address; readonly account: Address; readonly tokenId: bigint}

export type HoldingSnapshot =
  | {readonly assetType: 'native'; readonly account: Address; readonly balance: string}
  | {readonly assetType: 'erc20'; readonly token: Address; readonly account: Address; readonly balance: string}
  | {readonly assetType: 'erc721'; readonly token: Address; readonly tokenId: string; readonly owner: Address}
  | {readonly assetType: 'erc1155'; readonly token: Address; readonly account: Address; readonly tokenId: string; readonly balance: string}

export interface CrossChainSettlementSnapshot {
  readonly chainId: number
  readonly wrapper: Address
  readonly htlc: Address
  readonly htlcDeployed: boolean
  readonly htlcFunded: boolean
  readonly htlcReleased: boolean
  readonly state: keyof typeof CrossChainLegState
  readonly stateCode: CrossChainLegState
  readonly holdings: readonly HoldingSnapshot[]
}

export interface SettlementEventRecord {
  readonly source: ProtocolEvent['source']
  readonly address: Address
  readonly eventName: string
  readonly args: unknown
  readonly logIndex: number | null
}

export interface SettlementTransactionRecord {
  readonly sequence: number
  readonly action: SettlementAction
  readonly chainId: number
  readonly transactionHash: Hash
  readonly blockNumber: string
  readonly progressionGate: ProgressionGateOutcome
  readonly before: CrossChainSettlementSnapshot
  readonly after: CrossChainSettlementSnapshot
  readonly events: readonly SettlementEventRecord[]
}

export interface SettlementTraceArtifact {
  readonly schema: typeof SETTLEMENT_TRACE_SCHEMA
  readonly transactions: readonly SettlementTransactionRecord[]
  readonly finalSnapshots: readonly CrossChainSettlementSnapshot[]
}

type SuccessfulReceipt = Pick<TransactionReceipt, 'transactionHash' | 'status' | 'blockNumber' | 'logs'>

export class SettlementTraceRecorder {
  readonly #records: SettlementTransactionRecord[] = []
  readonly #latest = new Map<number, CrossChainSettlementSnapshot>()

  record(input: {
    readonly action: SettlementAction
    readonly receipt: SuccessfulReceipt
    readonly addresses: ProtocolAddresses
    readonly before: CrossChainSettlementSnapshot
    readonly after: CrossChainSettlementSnapshot
    readonly progressionGate: ProgressionGateOutcome
    readonly quipWallets?: readonly Address[]
  }): SettlementTransactionRecord {
    if (input.receipt.status !== 'success') throw new Error('settlement trace requires a successful receipt')
    if (input.before.chainId !== input.after.chainId || input.before.wrapper !== input.after.wrapper || input.before.htlc !== input.after.htlc) {
      throw new Error('settlement trace snapshot boundary mismatch')
    }
    validateHTLCLifecycle(input.before)
    validateHTLCLifecycle(input.after)
    validateTransition(input.action, input.before.stateCode, input.after.stateCode, input.progressionGate)
    const events = decodeProtocolEvents(
      input.receipt.logs as readonly Log[],
      input.addresses,
      input.quipWallets,
      [input.after.htlc],
    )
      .sort((left, right) => (left.logIndex ?? 0) - (right.logIndex ?? 0))
      .map(event => ({source: event.source, address: event.address, eventName: event.eventName, args: jsonValue(event.args), logIndex: event.logIndex}))
    const record: SettlementTransactionRecord = {
      sequence: this.#records.length + 1,
      action: input.action,
      chainId: input.before.chainId,
      transactionHash: input.receipt.transactionHash,
      blockNumber: input.receipt.blockNumber.toString(),
      progressionGate: input.progressionGate,
      before: input.before,
      after: input.after,
      events,
    }
    this.#records.push(record)
    this.#latest.set(record.chainId, record.after)
    return record
  }

  artifact(): SettlementTraceArtifact {
    return {
      schema: SETTLEMENT_TRACE_SCHEMA,
      transactions: this.#records.map(record => ({...record})),
      finalSnapshots: [...this.#latest.values()].sort((left, right) => left.chainId - right.chainId),
    }
  }
}

export async function readCrossChainSettlementSnapshot(args: {
  readonly publicClient: PublicClient
  readonly chainId: number
  readonly wrapper: Address
  readonly terms: ProtocolTerms
  readonly party: boolean
  readonly lock: Hex32
  readonly holdings: readonly TrackedHolding[]
}): Promise<CrossChainSettlementSnapshot> {
  const client = createProtocolClient({
    addresses: {
      assetSupportRegistry: zeroAddress,
      directAuthorization: zeroAddress,
      crossChainWrapper: args.wrapper,
      sameChainWrapper: zeroAddress,
    },
    publicClient: args.publicClient,
  })
  const [stateCode, deployedHTLC] = await Promise.all([
    client.getCrossChainState(args.terms, args.party, args.lock),
    client.getCrossChainHTLC(args.terms, args.party, args.lock),
  ])
  const htlcDeployed = deployedHTLC !== zeroAddress
  const htlc = htlcDeployed
    ? deployedHTLC
    : await client.predictCrossChainHTLC(args.terms, args.party, args.lock)
  const htlcState = htlcDeployed ? await client.getHTLCState(htlc) : undefined
  const holdings = await Promise.all(args.holdings.map(holding => readHolding(args.publicClient, holding)))
  return {
    chainId: args.chainId,
    wrapper: args.wrapper,
    htlc,
    htlcDeployed,
    htlcFunded: htlcState?.funded ?? false,
    htlcReleased: htlcState?.released ?? false,
    state: crossChainStateName(stateCode),
    stateCode,
    holdings,
  }
}

const balanceAbi = [
  {type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{name: 'account', type: 'address'}], outputs: [{name: '', type: 'uint256'}]},
] as const
const ownerAbi = [
  {type: 'function', name: 'ownerOf', stateMutability: 'view', inputs: [{name: 'tokenId', type: 'uint256'}], outputs: [{name: '', type: 'address'}]},
] as const
const multiBalanceAbi = [
  {type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{name: 'account', type: 'address'}, {name: 'id', type: 'uint256'}], outputs: [{name: '', type: 'uint256'}]},
] as const

async function readHolding(publicClient: PublicClient, holding: TrackedHolding): Promise<HoldingSnapshot> {
  if (holding.assetType === 'native') return {...holding, balance: (await publicClient.getBalance({address: holding.account})).toString()}
  if (holding.assetType === 'erc721') {
    const owner = await publicClient.readContract({address: holding.token, abi: ownerAbi, functionName: 'ownerOf', args: [holding.tokenId]})
    return {...holding, tokenId: holding.tokenId.toString(), owner}
  }
  if (holding.assetType === 'erc1155') {
    const balance = await publicClient.readContract({address: holding.token, abi: multiBalanceAbi, functionName: 'balanceOf', args: [holding.account, holding.tokenId]})
    return {...holding, tokenId: holding.tokenId.toString(), balance: balance.toString()}
  }
  const balance = await publicClient.readContract({address: holding.token, abi: balanceAbi, functionName: 'balanceOf', args: [holding.account]})
  return {...holding, balance: balance.toString()}
}

function validateTransition(action: SettlementAction, before: CrossChainLegState, after: CrossChainLegState, gate: ProgressionGateOutcome): void {
  const expected = action === 'alice-commit'
    ? [CrossChainLegState.Unused, CrossChainLegState.Committed, 'bob-secret-published'] as const
    : action === 'bob-commit'
      ? [CrossChainLegState.Unused, CrossChainLegState.Committed, 'bob-secret-accepted'] as const
      : action === 'reclaim'
        ? [CrossChainLegState.Committed, CrossChainLegState.Reclaimed, 'not-applicable'] as const
        : [CrossChainLegState.Committed, CrossChainLegState.Claimed, 'not-applicable'] as const
  if (before !== expected[0] || after !== expected[1] || gate !== expected[2]) throw new Error('invalid settlement trace transition')
}

function validateHTLCLifecycle(snapshot: CrossChainSettlementSnapshot): void {
  const unused = snapshot.stateCode === CrossChainLegState.Unused
  const terminal = snapshot.stateCode === CrossChainLegState.Claimed || snapshot.stateCode === CrossChainLegState.Reclaimed
  if (snapshot.htlcDeployed !== !unused || snapshot.htlcFunded !== !unused || snapshot.htlcReleased !== terminal) {
    throw new Error('wrapper state and HTLC lifecycle disagree')
  }
}

function crossChainStateName(state: CrossChainLegState): keyof typeof CrossChainLegState {
  if (state === CrossChainLegState.Unused) return 'Unused'
  if (state === CrossChainLegState.Committed) return 'Committed'
  if (state === CrossChainLegState.Claimed) return 'Claimed'
  if (state === CrossChainLegState.Reclaimed) return 'Reclaimed'
  throw new Error('unknown cross-chain state')
}

function jsonValue(value: unknown): unknown {
  if (typeof value === 'bigint') return value.toString()
  if (Array.isArray(value)) return value.map(jsonValue)
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, jsonValue(entry)]))
  }
  return value
}

export function serializeSettlementTrace(artifact: SettlementTraceArtifact): string {
  return `${JSON.stringify(artifact, null, 2)}\n`
}
