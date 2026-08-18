import {encodeAbiParameters, encodeEventTopics} from 'viem'
import type {Address, Hash, Log, TransactionReceipt} from 'viem'
import {describe, expect, it} from 'vitest'
import {
  SETTLEMENT_TRACE_SCHEMA,
  SettlementTraceRecorder,
  serializeSettlementTrace,
} from '../../scripts/demo-settlement-trace.js'
import {CrossChainLegState, crossChainWrapperAbi} from '../../src/index.js'
import type {CrossChainSettlementSnapshot} from '../../scripts/demo-settlement-trace.js'
import type {ProtocolAddresses} from '../../src/index.js'

const address = (digit: string) => `0x${digit.repeat(40)}` as Address
const hash = (digit: string) => `0x${digit.repeat(64)}` as Hash
const WRAPPER_A = address('1')
const WRAPPER_B = address('2')
const PRINCIPAL = address('3')
const TOKEN = address('4')
const addresses = (wrapper: Address): ProtocolAddresses => ({
  assetSupportRegistry: address('5'),
  identityRegistry: address('7'),
  authorizationGateway: address('8'),
  crossChainWrapper: wrapper,
  sameChainWrapper: address('9'),
})

function snapshot(chainId: number, wrapper: Address, stateCode: CrossChainLegState, balance: bigint): CrossChainSettlementSnapshot {
  const names = ['Unused', 'Committed', 'Claimed', 'Reclaimed'] as const
  return {chainId, wrapper, state: names[stateCode], stateCode, holdings: [{assetType: 'erc20', token: TOKEN, account: PRINCIPAL, balance: balance.toString()}]}
}

function eventLog(wrapper: Address, eventName: 'Committed' | 'Claimed', transactionHash: Hash, logIndex: number): Log {
  const args = {tradeId: hash('a'), lock: hash('b'), side: 0, ...(eventName === 'Committed' ? {principal: PRINCIPAL} : {})}
  const topics = encodeEventTopics({abi: crossChainWrapperAbi, eventName, args})
  const data = eventName === 'Committed' ? encodeAbiParameters([{type: 'address'}], [PRINCIPAL]) : '0x'
  return {address: wrapper, topics, data, blockNumber: 10n, transactionHash, logIndex} as Log
}

function receipt(transactionHash: Hash, logs: readonly Log[]): Pick<TransactionReceipt, 'transactionHash' | 'status' | 'blockNumber' | 'logs'> {
  return {transactionHash, status: 'success', blockNumber: 10n, logs: [...logs] as TransactionReceipt['logs']}
}

describe('demo on-chain settlement trace', () => {
  it('records ordered transactions, decoded events, progression gates, states, and final holdings', () => {
    const trace = new SettlementTraceRecorder()
    const a0 = snapshot(31337, WRAPPER_A, CrossChainLegState.Unused, 10n)
    const a1 = snapshot(31337, WRAPPER_A, CrossChainLegState.Committed, 0n)
    const b0 = snapshot(31338, WRAPPER_B, CrossChainLegState.Unused, 20n)
    const b1 = snapshot(31338, WRAPPER_B, CrossChainLegState.Committed, 0n)
    const b2 = snapshot(31338, WRAPPER_B, CrossChainLegState.Claimed, 0n)
    const a2 = snapshot(31337, WRAPPER_A, CrossChainLegState.Claimed, 0n)
    trace.record({action: 'alice-commit', receipt: receipt(hash('1'), [eventLog(WRAPPER_A, 'Committed', hash('1'), 1)]), addresses: addresses(WRAPPER_A), before: a0, after: a1, progressionGate: 'bob-secret-published'})
    trace.record({action: 'bob-commit', receipt: receipt(hash('2'), [eventLog(WRAPPER_B, 'Committed', hash('2'), 1)]), addresses: addresses(WRAPPER_B), before: b0, after: b1, progressionGate: 'bob-secret-accepted'})
    trace.record({action: 'revealing-claim', receipt: receipt(hash('3'), [eventLog(WRAPPER_B, 'Claimed', hash('3'), 1)]), addresses: addresses(WRAPPER_B), before: b1, after: b2, progressionGate: 'not-applicable'})
    trace.record({action: 'final-claim', receipt: receipt(hash('4'), [eventLog(WRAPPER_A, 'Claimed', hash('4'), 1)]), addresses: addresses(WRAPPER_A), before: a1, after: a2, progressionGate: 'not-applicable'})
    const artifact = trace.artifact()
    expect(artifact.schema).toBe(SETTLEMENT_TRACE_SCHEMA)
    expect(artifact.transactions.map(entry => [entry.sequence, entry.transactionHash, entry.events[0]?.eventName])).toEqual([
      [1, hash('1'), 'Committed'], [2, hash('2'), 'Committed'], [3, hash('3'), 'Claimed'], [4, hash('4'), 'Claimed'],
    ])
    expect(artifact.finalSnapshots.map(entry => [entry.chainId, entry.state])).toEqual([[31337, 'Claimed'], [31338, 'Claimed']])
    expect(serializeSettlementTrace(artifact)).toContain('bob-secret-accepted')
  })

  it('rejects failed receipts, wrong progression outcomes, and impossible transitions', () => {
    const trace = new SettlementTraceRecorder()
    const unused = snapshot(31337, WRAPPER_A, CrossChainLegState.Unused, 10n)
    const committed = snapshot(31337, WRAPPER_A, CrossChainLegState.Committed, 0n)
    expect(() => trace.record({action: 'alice-commit', receipt: {...receipt(hash('1'), []), status: 'reverted'}, addresses: addresses(WRAPPER_A), before: unused, after: committed, progressionGate: 'bob-secret-published'})).toThrow('successful receipt')
    expect(() => trace.record({action: 'bob-commit', receipt: receipt(hash('2'), []), addresses: addresses(WRAPPER_A), before: unused, after: committed, progressionGate: 'not-applicable'})).toThrow('transition')
    expect(() => trace.record({action: 'final-claim', receipt: receipt(hash('3'), []), addresses: addresses(WRAPPER_A), before: unused, after: committed, progressionGate: 'not-applicable'})).toThrow('transition')
  })

  it('orders decoded events by log index', () => {
    const trace = new SettlementTraceRecorder()
    const before = snapshot(31337, WRAPPER_A, CrossChainLegState.Unused, 10n)
    const after = snapshot(31337, WRAPPER_A, CrossChainLegState.Committed, 0n)
    const late = eventLog(WRAPPER_A, 'Committed', hash('1'), 8)
    const early = eventLog(WRAPPER_A, 'Committed', hash('1'), 2)
    const record = trace.record({action: 'alice-commit', receipt: receipt(hash('1'), [late, early]), addresses: addresses(WRAPPER_A), before, after, progressionGate: 'bob-secret-published'})
    expect(record.events.map(event => event.logIndex)).toEqual([2, 8])
  })
})
