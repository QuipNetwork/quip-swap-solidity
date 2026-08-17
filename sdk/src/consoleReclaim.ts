import {readFile} from 'node:fs/promises'
import {join, resolve} from 'node:path'
import {createPublicClient, createWalletClient, defineChain, http} from 'viem'
import type {Address, Hash, PublicClient, Transaction, WalletClient} from 'viem'
import {privateKeyToAccount} from 'viem/accounts'
import {applyPartyCommand} from './cliCommands.js'
import {loadConsoleRuntimeConfig} from './consoleTrade.js'
import type {ConsoleRuntimeConfig} from './consoleTrade.js'
import {loadConsoleConfigIdentity, publishLockedWorkspaceWorkflowState, restoreWorkspaceWorkflowState, withWorkspaceMutation, writeLockedWorkspaceJournal} from './consoleWorkspace.js'
import {createProtocolClient} from './protocolClient.js'
import {CrossChainLegState} from './protocol.js'
import type {ProtocolTerms} from './protocol.js'
import type {Hex32} from './types.js'

export const RECLAIM_JOURNAL_SCHEMA = 'quip-swap-transaction-journal.v1' as const
export const RECOVERY_INPUT_SCHEMA = 'quip-swap-recovery.v1' as const
const ALICE_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' as const
const BOB_KEY = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a' as const

export type ReclaimTransactionLifecycle = 'pending' | 'success' | 'dropped' | 'replaced' | 'reverted'
export interface ReclaimTransactionStatus {readonly lifecycle: ReclaimTransactionLifecycle; readonly replacementHash?: Hash}
export interface ReclaimPreview {readonly chainId: number; readonly wrapper: Address; readonly submitter: Address; readonly reclaimRecipient: Address; readonly reclaimRelease: string; readonly payouts: readonly {readonly token: Address; readonly amount: string}[]; readonly authorization: 'permissionless'}
export interface ReclaimBoundary {
  readonly state: (terms: ProtocolTerms, party: boolean, lock: Hex32) => Promise<CrossChainLegState>
  readonly timestamp: () => Promise<bigint>
  readonly transaction: (hash: Hash, metadata: {readonly sender: Address; readonly nonce: number; readonly submittedAtBlock: bigint}) => Promise<ReclaimTransactionStatus>
  readonly submit: (args: {readonly terms: ProtocolTerms; readonly party: boolean; readonly lock: Hex32}) => Promise<{readonly hash: Hash; readonly nonce: number; readonly submittedAtBlock: bigint}>
}

function local(config: ConsoleRuntimeConfig): {readonly submitter: Address; readonly boundary: ReclaimBoundary} {
  const party = config.identity.localParty === 'alice'
  const index = party ? 0 : 1
  const route = config.chains[index]
  const account = privateKeyToAccount(party ? ALICE_KEY : BOB_KEY)
  const submitter = party ? config.actors.alice : config.actors.bob
  if (account.address.toLowerCase() !== submitter.toLowerCase()) throw new Error('local reclaim account does not match configuration')
  const chain = defineChain({id: route.chainId, name: `anvil-${route.chainId}`, nativeCurrency: {name: 'Ether', symbol: 'ETH', decimals: 18}, rpcUrls: {default: {http: [route.rpcUrl]}}})
  const publicClient = createPublicClient({chain, transport: http(route.rpcUrl)}) as PublicClient
  const walletClient = createWalletClient({chain, transport: http(route.rpcUrl), account}) as WalletClient
  const client = createProtocolClient({addresses: route.addresses as never, publicClient, walletClient})
  return {submitter, boundary: {
    state: (terms, selectedParty, lock) => client.getCrossChainState(terms, selectedParty, lock),
    timestamp: async () => (await publicClient.getBlock()).timestamp,
    transaction: async (hash, metadata) => {
      try {return {lifecycle: (await publicClient.getTransactionReceipt({hash})).status === 'success' ? 'success' : 'reverted'}} catch {}
      try {await publicClient.getTransaction({hash}); return {lifecycle: 'pending'}} catch {}
      if (await publicClient.getTransactionCount({address: metadata.sender, blockTag: 'latest'}) <= metadata.nonce) return {lifecycle: 'dropped'}
      const head = await publicClient.getBlockNumber()
      const scanFrom = head - metadata.submittedAtBlock > 512n ? head - 512n : metadata.submittedAtBlock
      for (let number = scanFrom; number <= head; number += 1n) {
        const block = await publicClient.getBlock({blockNumber: number, includeTransactions: true})
        const replacement = (block.transactions as Transaction[]).find(tx => tx.from.toLowerCase() === metadata.sender.toLowerCase() && tx.nonce === metadata.nonce && tx.hash !== hash)
        if (replacement !== undefined) return {lifecycle: 'replaced', replacementHash: replacement.hash}
      }
      return {lifecycle: 'replaced'}
    },
    submit: async args => {const hash = await client.reclaimCrossChain(args.terms, args.party, args.lock); const [transaction, block] = await Promise.all([publicClient.getTransaction({hash}), publicClient.getBlockNumber()]); return {hash, nonce: transaction.nonce, submittedAtBlock: block}},
  }}
}

function object(value: unknown): Record<string, unknown> {if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error('invalid reclaim journal'); return value as Record<string, unknown>}
const missing = (error: unknown) => error instanceof Error && 'code' in error && error.code === 'ENOENT'

export async function submitReclaim(args: {readonly workspace: string; readonly configPath: string; readonly boundary?: ReclaimBoundary; readonly submitter?: Address; readonly onPreview?: (preview: ReclaimPreview) => void}): Promise<{readonly tradeId: Hex32; readonly transactionHash: Hash; readonly lifecycle: ReclaimTransactionLifecycle | 'already-mined'; readonly reused: boolean; readonly preview: ReclaimPreview}> {
  const configIdentity = await loadConsoleConfigIdentity(args.configPath)
  const config = await loadConsoleRuntimeConfig(args.configPath, configIdentity.localParty)
  const configured = args.boundary === undefined ? local(config) : undefined
  const boundary = args.boundary ?? configured!.boundary
  const submitter = args.submitter ?? configured!.submitter
  const party = config.identity.localParty === 'alice'
  return withWorkspaceMutation(args.workspace, async () => {
    const expected = {party: config.identity.localParty, networkId: config.identity.networkId, configDigest: config.identity.digest}
    const restored = await restoreWorkspaceWorkflowState(args.workspace, expected)
    const side = party ? restored.terms.partySide : restored.terms.counterpartySide
    const route = config.chains[party ? 0 : 1]
    const preview: ReclaimPreview = {chainId: route.chainId, wrapper: route.wrapper, submitter, reclaimRecipient: side.reclaimRecipient, reclaimRelease: side.reclaimRelease.toString(), payouts: side.assets.map(asset => ({token: asset.target, amount: asset.amount.toString()})), authorization: 'permissionless'}
    args.onPreview?.(preview)
    const journalPath = join(resolve(args.workspace), 'journal', `reclaim-${route.chainId}.json`)
    try {
      const journal = object(JSON.parse(await readFile(journalPath, 'utf8')))
      if (journal['schema'] !== RECLAIM_JOURNAL_SCHEMA || journal['action'] !== 'reclaim' || journal['tradeId'] !== restored.publicState.tradeId || journal['chainId'] !== route.chainId || typeof journal['wrapper'] !== 'string' || journal['wrapper'].toLowerCase() !== route.wrapper.toLowerCase() || typeof journal['submitter'] !== 'string' || journal['submitter'].toLowerCase() !== submitter.toLowerCase() || typeof journal['transactionHash'] !== 'string') throw new Error('reclaim journal binding mismatch')
      const hash = journal['transactionHash'] as Hash
      if (!Number.isSafeInteger(journal['nonce']) || typeof journal['submittedAtBlock'] !== 'string' || !/^[0-9]+$/.test(journal['submittedAtBlock'])) throw new Error('invalid reclaim journal transaction metadata')
      const transaction = await boundary.transaction(hash, {sender: submitter, nonce: journal['nonce'] as number, submittedAtBlock: BigInt(journal['submittedAtBlock'])})
      const reconciledHash = transaction.replacementHash ?? hash
      if (transaction.lifecycle === 'success' || transaction.lifecycle === 'pending') return {tradeId: restored.publicState.tradeId, transactionHash: reconciledHash, lifecycle: transaction.lifecycle, reused: true, preview}
      const state = await boundary.state(restored.terms, party, restored.publicState.derived.settlementLock)
      if (state === CrossChainLegState.Reclaimed) return {tradeId: restored.publicState.tradeId, transactionHash: reconciledHash, lifecycle: 'already-mined', reused: true, preview}
      return {tradeId: restored.publicState.tradeId, transactionHash: reconciledHash, lifecycle: transaction.lifecycle, reused: true, preview}
    } catch (error) {if (!missing(error)) throw error}
    const [state, now] = await Promise.all([boundary.state(restored.terms, party, restored.publicState.derived.settlementLock), boundary.timestamp()])
    if (state !== CrossChainLegState.Committed) throw new Error('reclaim requires the exact Committed state')
    if (now < side.reclaimRelease) throw new Error(`reclaim is not enabled before ${side.reclaimRelease}`)
    const submitted = await boundary.submit({terms: restored.terms, party, lock: restored.publicState.derived.settlementLock})
    await writeLockedWorkspaceJournal(args.workspace, `reclaim-${route.chainId}`, `${JSON.stringify({schema: RECLAIM_JOURNAL_SCHEMA, action: 'reclaim', networkId: config.identity.networkId, tradeId: restored.publicState.tradeId, chainId: route.chainId, wrapper: route.wrapper, transactionHash: submitted.hash, submitter, nonce: submitted.nonce, submittedAtBlock: submitted.submittedAtBlock.toString(), reclaimRecipient: side.reclaimRecipient}, null, 2)}\n`)
    const next = applyPartyCommand(restored.publicState, restored.secretState, {command: 'record-observation'})
    await publishLockedWorkspaceWorkflowState({root: args.workspace, expected: {...expected, tradeId: restored.publicState.tradeId, generation: restored.publicState.generation}, publicState: next.publicState, secretState: next.secretState})
    return {tradeId: restored.publicState.tradeId, transactionHash: submitted.hash, lifecycle: 'pending', reused: false, preview}
  })
}

export async function enterConsoleRecovery(args: {readonly workspace: string; readonly configPath: string; readonly input: string}): Promise<{readonly tradeId: Hex32; readonly reason: string}> {
  const value = object(JSON.parse(args.input))
  if (value['schema'] !== RECOVERY_INPUT_SCHEMA || typeof value['reason'] !== 'string' || value['reason'].trim() === '' || value['reason'].length > 500) throw new Error('invalid recovery input')
  if (/secret|preimage|private.?key/i.test(value['reason'])) throw new Error('recovery reason may not contain sensitive material')
  const identity = await loadConsoleConfigIdentity(args.configPath)
  return withWorkspaceMutation(args.workspace, async () => {
    const expected = {party: identity.localParty, networkId: identity.networkId, configDigest: identity.digest}
    const restored = await restoreWorkspaceWorkflowState(args.workspace, expected)
    const next = applyPartyCommand(restored.publicState, restored.secretState, {command: 'enter-recovery', reason: value['reason'] as string})
    await publishLockedWorkspaceWorkflowState({root: args.workspace, expected: {...expected, tradeId: restored.publicState.tradeId, generation: restored.publicState.generation}, publicState: next.publicState, secretState: next.secretState})
    return {tradeId: restored.publicState.tradeId, reason: value['reason'] as string}
  })
}
