import {readFile} from 'node:fs/promises'
import {join, resolve} from 'node:path'
import {createPublicClient, defineChain, http} from 'viem'
import type {Address, Hash, PublicClient, Transaction, TransactionReceipt} from 'viem'
import {applyPartyCommand} from './cliCommands.js'
import type {PersistedInclusion} from './clientState.js'
import {ALICE_COMMIT_JOURNAL_SCHEMA, ALICE_COMMIT_REFERENCE_SCHEMA} from './consoleCommit.js'
import {loadConsoleRuntimeConfig} from './consoleTrade.js'
import type {ConsoleRuntimeConfig} from './consoleTrade.js'
import {CrossChainLegState} from './protocol.js'
import type {ProtocolTerms} from './protocol.js'
import {decodeProtocolEvents} from './protocolEvents.js'
import {createProtocolClient} from './protocolClient.js'
import {loadConsoleConfigIdentity, publishLockedWorkspaceWorkflowState, restoreWorkspaceWorkflowState, withWorkspaceMutation} from './consoleWorkspace.js'
import type {Hex32} from './types.js'

export const ALICE_COMMIT_OBSERVATION_SCHEMA = 'quip-swap-alice-commit-observation.v1' as const

export type AliceCommitLifecycle = 'pending' | 'included-non-final' | 'final' | 'replaced' | 'dropped' | 'reorganized' | 'reverted'

interface CommitReference {
  readonly networkId: string
  readonly tradeId: Hex32
  readonly chainId: 31337
  readonly wrapper: Address
  readonly transactionHash: Hash
  readonly sender: Address
  readonly nonce: number
  readonly submittedAtBlock: string
}

export interface AliceCommitObservation {
  readonly schema: typeof ALICE_COMMIT_OBSERVATION_SCHEMA
  readonly networkId: string
  readonly tradeId: Hex32
  readonly chainId: 31337
  readonly wrapper: Address
  readonly transactionHash: Hash
  readonly lifecycle: AliceCommitLifecycle
  readonly observedHead: string
  readonly confirmations: string
  readonly requiredConfirmations: string
  readonly inclusion?: PersistedInclusion
  readonly replacementHash?: Hash
  readonly bobCommitEnabled: boolean
  readonly warning?: string
}

export interface AliceCommitObservationBoundary {
  inspect(args: {readonly reference: CommitReference; readonly terms: ProtocolTerms; readonly lock: Hex32; readonly requiredConfirmations: bigint; readonly principal: Address}): Promise<Omit<AliceCommitObservation, 'schema' | 'networkId' | 'tradeId' | 'chainId' | 'wrapper' | 'transactionHash' | 'requiredConfirmations' | 'bobCommitEnabled' | 'warning'>>
}

const object = (value: unknown, label: string): Record<string, unknown> => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${label} must be an object`)
  return value as Record<string, unknown>
}
const hex32 = (value: unknown): value is Hex32 => typeof value === 'string' && /^0x[0-9a-fA-F]{64}$/.test(value)
const address = (value: unknown): value is Address => typeof value === 'string' && /^0x[0-9a-fA-F]{40}$/.test(value)

function parseReference(serialized: string): CommitReference {
  const value = object(JSON.parse(serialized), 'Alice commit reference')
  if (value['schema'] !== ALICE_COMMIT_JOURNAL_SCHEMA && value['schema'] !== ALICE_COMMIT_REFERENCE_SCHEMA) throw new Error('unsupported Alice commit reference')
  if (typeof value['networkId'] !== 'string' || !hex32(value['tradeId']) || value['chainId'] !== 31337 || !address(value['wrapper']) || !hex32(value['transactionHash']) || !address(value['sender']) || !Number.isSafeInteger(value['nonce']) || typeof value['submittedAtBlock'] !== 'string' || !/^[0-9]+$/.test(value['submittedAtBlock'])) throw new Error('invalid Alice commit reference')
  return value as unknown as CommitReference
}

async function replacement(publicClient: PublicClient, reference: CommitReference, head: bigint): Promise<{readonly lifecycle: 'replaced' | 'dropped'; readonly replacementHash?: Hash}> {
  const confirmedNonce = await publicClient.getTransactionCount({address: reference.sender, blockTag: 'latest'})
  if (confirmedNonce <= reference.nonce) return {lifecycle: 'dropped'}
  const first = BigInt(reference.submittedAtBlock)
  const scanFrom = head - first > 512n ? head - 512n : first
  for (let number = scanFrom; number <= head; number += 1n) {
    const block = await publicClient.getBlock({blockNumber: number, includeTransactions: true})
    const found = (block.transactions as Transaction[]).find(tx => tx.from.toLowerCase() === reference.sender.toLowerCase() && tx.nonce === reference.nonce && tx.hash !== reference.transactionHash)
    if (found !== undefined) return {lifecycle: 'replaced', replacementHash: found.hash}
  }
  return {lifecycle: 'replaced'}
}

export function createLocalAliceObservationBoundary(config: ConsoleRuntimeConfig): AliceCommitObservationBoundary {
  const route = config.chains[0]
  const chain = defineChain({id: 31337, name: 'anvil-31337', nativeCurrency: {name: 'Ether', symbol: 'ETH', decimals: 18}, rpcUrls: {default: {http: [route.rpcUrl]}}})
  const publicClient = createPublicClient({chain, transport: http(route.rpcUrl)}) as PublicClient
  const addresses = route.addresses as unknown as Parameters<typeof createProtocolClient>[0]['addresses']
  const client = createProtocolClient({addresses, publicClient})
  return {inspect: async ({reference, terms, lock, requiredConfirmations, principal}) => {
    const head = await publicClient.getBlockNumber()
    let receipt: TransactionReceipt
    try { receipt = await publicClient.getTransactionReceipt({hash: reference.transactionHash}) } catch {
      try { await publicClient.getTransaction({hash: reference.transactionHash}); return {lifecycle: 'pending', observedHead: head.toString(), confirmations: '0'} } catch {
        const missing = await replacement(publicClient, reference, head)
        return {...missing, observedHead: head.toString(), confirmations: '0'}
      }
    }
    if (receipt.status !== 'success') return {lifecycle: 'reverted', observedHead: head.toString(), confirmations: '0'}
    if (receipt.blockHash === null) throw new Error('Alice commit receipt lacks block hash')
    let canonicalHash: Hex32 | undefined
    try { canonicalHash = (await publicClient.getBlock({blockNumber: receipt.blockNumber})).hash as Hex32 } catch {}
    const inclusion: PersistedInclusion = {transactionHash: receipt.transactionHash, blockNumber: receipt.blockNumber.toString(), blockHash: receipt.blockHash as Hex32}
    if (canonicalHash === undefined || canonicalHash !== receipt.blockHash) return {lifecycle: 'reorganized', observedHead: head.toString(), confirmations: '0', inclusion}
    const events = decodeProtocolEvents(receipt.logs, addresses).filter(event => event.source === 'crossChainWrapper' && event.eventName === 'Committed')
    const valid = events.filter(event => {
      const args = object(event.args, 'Committed event')
      return args['tradeId'] === reference.tradeId && args['lock'] === lock && args['side'] === 0 && typeof args['principal'] === 'string' && args['principal'].toLowerCase() === principal.toLowerCase() && event.address.toLowerCase() === reference.wrapper.toLowerCase() && event.transactionHash === reference.transactionHash
    })
    if (valid.length !== 1) throw new Error('Alice transaction lacks one exact authenticated Committed event')
    if (await client.getCrossChainState(terms, true, lock) !== CrossChainLegState.Committed) throw new Error('Alice committed event disagrees with wrapper state')
    const confirmations = head >= receipt.blockNumber ? head - receipt.blockNumber + 1n : 0n
    return {lifecycle: confirmations >= requiredConfirmations ? 'final' : 'included-non-final', observedHead: head.toString(), confirmations: confirmations.toString(), inclusion}
  }}
}

async function loadReference(workspace: string, config: ConsoleRuntimeConfig, tradeId: Hex32): Promise<CommitReference> {
  const path = config.identity.localParty === 'alice'
    ? join(resolve(workspace), 'journal', 'alice-commit.json')
    : join(resolve(config.exchangeDirectory), `alice-commit-${tradeId.slice(2)}.json`)
  return parseReference(await readFile(path, 'utf8'))
}

export async function observeAliceCommit(args: {readonly workspace: string; readonly configPath: string; readonly boundary?: AliceCommitObservationBoundary}): Promise<AliceCommitObservation> {
  const identity = await loadConsoleConfigIdentity(args.configPath)
  const config = await loadConsoleRuntimeConfig(args.configPath, identity.localParty)
  return withWorkspaceMutation(args.workspace, async () => {
    const expected = {party: identity.localParty, networkId: identity.networkId, configDigest: identity.digest}
    const restored = await restoreWorkspaceWorkflowState(args.workspace, expected)
    const reference = await loadReference(args.workspace, {...config, identity}, restored.publicState.tradeId)
    if (reference.networkId !== identity.networkId || reference.tradeId !== restored.publicState.tradeId || reference.wrapper.toLowerCase() !== config.chains[0].wrapper.toLowerCase() || reference.sender.toLowerCase() !== config.actors.alice.toLowerCase()) throw new Error('Alice commit reference binding mismatch')
    const observed = await (args.boundary ?? createLocalAliceObservationBoundary({...config, identity})).inspect({reference, terms: restored.terms, lock: restored.publicState.derived.settlementLock, requiredConfirmations: config.requiredConfirmations, principal: config.actors.alice})
    const final = observed.lifecycle === 'final'
    const observation: AliceCommitObservation = {schema: ALICE_COMMIT_OBSERVATION_SCHEMA, networkId: identity.networkId, tradeId: restored.publicState.tradeId, chainId: 31337, wrapper: config.chains[0].wrapper, transactionHash: reference.transactionHash, ...observed, requiredConfirmations: config.requiredConfirmations.toString(), bobCommitEnabled: final, ...(!final ? {warning: observed.lifecycle === 'included-non-final' ? `Alice commit is not final; ${observed.confirmations}/${config.requiredConfirmations} confirmations.` : `Alice commit is ${observed.lifecycle}; Bob commit remains disabled.`} : {})}
    const progressionDisclosed = restored.publicState.party === 'alice'
      ? restored.publicState.progression.released
      : restored.publicState.progression.received
    const command = final
      ? {command: 'mark-alice-final' as const, inclusion: observed.inclusion!}
      : progressionDisclosed
        ? {command: 'enter-recovery' as const, reason: `Alice commit became ${observed.lifecycle} after progression disclosure; stop Bob submission and reclaim eligible committed legs.`}
        : observed.lifecycle === 'included-non-final'
          ? {command: 'mark-alice-included-non-final' as const, inclusion: observed.inclusion!}
          : {command: 'mark-alice-pending' as const}
    const next = applyPartyCommand(restored.publicState, restored.secretState, command)
    await publishLockedWorkspaceWorkflowState({root: args.workspace, expected: {...expected, tradeId: restored.publicState.tradeId, generation: restored.publicState.generation}, publicState: next.publicState, secretState: next.secretState, publicArtifacts: {'alice-commit-observation.json': `${JSON.stringify(observation, null, 2)}\n`}})
    return observation
  })
}
