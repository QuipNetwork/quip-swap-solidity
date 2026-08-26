import {mkdir, open, readFile} from 'node:fs/promises'
import {join, resolve} from 'node:path'
import {createPublicClient, createWalletClient, defineChain, http} from 'viem'
import type {Address, Hash, Hex, PublicClient, WalletClient} from 'viem'
import {privateKeyToAccount} from 'viem/accounts'
import {loadConsoleRuntimeConfig} from './consoleTrade.js'
import type {ConsoleRuntimeConfig} from './consoleTrade.js'
import {CrossChainLegState} from './protocol.js'
import type {ProtocolTerms} from './protocol.js'
import {createProtocolClient} from './protocolClient.js'
import {restoreWorkspaceWorkflowState, withWorkspaceMutation, writeLockedWorkspaceJournal} from './consoleWorkspace.js'
import type {Hex32} from './types.js'

export const REVEALING_CLAIM_INPUT_SCHEMA = 'quip-swap-revealing-claim.v1' as const
export const REVEALING_CLAIM_REFERENCE_SCHEMA = 'quip-swap-revealing-claim-reference.v1' as const
const JOURNAL_SCHEMA = 'quip-swap-transaction-journal.v1' as const
const ANVIL_ALICE_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' as Hex

interface RevealReference {
  readonly networkId: string
  readonly tradeId: Hex32
  readonly chainId: 31338
  readonly wrapper: Address
  readonly transactionHash: Hash
  readonly sender: Address
  readonly nonce: number
  readonly submittedAtBlock: string
}

export interface RevealingClaimPreview {
  readonly chainId: 31338
  readonly wrapper: Address
  readonly htlc: Address
  readonly recipient: Address
  readonly payouts: readonly {readonly token: Address; readonly amount: string; readonly htlcChange: string; readonly recipientChange: string}[]
  readonly claimDeadline: string
  readonly disclosure: 'settlement preimage becomes public in transaction calldata'
}

export interface RevealingClaimBoundary {
  state(terms: ProtocolTerms, lock: Hex32): Promise<CrossChainLegState>
  htlc(terms: ProtocolTerms, lock: Hex32): Promise<Address>
  transaction(hash: Hash): Promise<'pending' | 'success' | 'reverted' | 'missing'>
  submit(args: {readonly terms: ProtocolTerms; readonly lock: Hex32; readonly secret: Hex32}): Promise<{readonly hash: Hash; readonly nonce: number; readonly submittedAtBlock: bigint}>
}

const object = (value: unknown, label: string): Record<string, unknown> => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${label} must be an object`)
  return value as Record<string, unknown>
}

function confirmation(serialized: string): void {
  if (/settlementSecret|bobCommitSecret|privateKey|signature/i.test(serialized)) throw new Error('revealing-claim confirmation contains sensitive material')
  const value = object(JSON.parse(serialized), 'revealing-claim confirmation')
  if (value['schema'] !== REVEALING_CLAIM_INPUT_SCHEMA || value['confirmed'] !== true) throw new Error('revealing claim requires explicit confirmed=true input')
}

function preview(config: ConsoleRuntimeConfig, terms: ProtocolTerms, htlc: Address): RevealingClaimPreview {
  const side = terms.counterpartySide
  return {chainId: 31338, wrapper: config.chains[1].wrapper, htlc, recipient: side.recipient, payouts: side.assets.map(asset => ({token: asset.target, amount: asset.amount.toString(), htlcChange: `-${asset.amount}`, recipientChange: `+${asset.amount}`})), claimDeadline: side.claimDeadline.toString(), disclosure: 'settlement preimage becomes public in transaction calldata'}
}

function parseReference(serialized: string): RevealReference {
  const value = object(JSON.parse(serialized), 'revealing-claim journal')
  if (value['schema'] !== JOURNAL_SCHEMA || value['action'] !== 'revealing-claim' || typeof value['networkId'] !== 'string' || typeof value['tradeId'] !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value['tradeId']) || value['chainId'] !== 31338 || typeof value['wrapper'] !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value['wrapper']) || typeof value['transactionHash'] !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value['transactionHash']) || typeof value['sender'] !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value['sender']) || !Number.isSafeInteger(value['nonce']) || typeof value['submittedAtBlock'] !== 'string' || !/^[0-9]+$/.test(value['submittedAtBlock'])) throw new Error('invalid revealing-claim journal')
  return value as unknown as RevealReference
}

async function publishReference(config: ConsoleRuntimeConfig, reference: RevealReference): Promise<void> {
  await mkdir(config.exchangeDirectory, {recursive: true, mode: 0o700})
  const path = join(resolve(config.exchangeDirectory), `revealing-claim-${reference.tradeId.slice(2)}.json`)
  const contents = `${JSON.stringify({schema: REVEALING_CLAIM_REFERENCE_SCHEMA, networkId: reference.networkId, tradeId: reference.tradeId, chainId: reference.chainId, wrapper: reference.wrapper, transactionHash: reference.transactionHash, sender: reference.sender, nonce: reference.nonce, submittedAtBlock: reference.submittedAtBlock}, null, 2)}\n`
  try {
    const handle = await open(path, 'wx', 0o600)
    try { await handle.writeFile(contents, 'utf8'); await handle.sync() } finally { await handle.close() }
  } catch (error) {
    if (!(error instanceof Error && 'code' in error && error.code === 'EEXIST')) throw error
    if (await readFile(path, 'utf8') !== contents) throw new Error('revealing-claim reference already exists with different contents')
  }
}

export function createLocalRevealingClaimBoundary(config: ConsoleRuntimeConfig): RevealingClaimBoundary {
  const route = config.chains[1]
  const chain = defineChain({id: 31338, name: 'anvil-31338', nativeCurrency: {name: 'Ether', symbol: 'ETH', decimals: 18}, rpcUrls: {default: {http: [route.rpcUrl]}}})
  const account = privateKeyToAccount(ANVIL_ALICE_KEY)
  if (account.address.toLowerCase() !== config.actors.alice.toLowerCase()) throw new Error('local Alice account does not match configuration')
  const publicClient = createPublicClient({chain, transport: http(route.rpcUrl)}) as PublicClient
  const walletClient = createWalletClient({chain, transport: http(route.rpcUrl), account}) as WalletClient
  const client = createProtocolClient({addresses: route.addresses as unknown as Parameters<typeof createProtocolClient>[0]['addresses'], publicClient, walletClient})
  return {
    state: (terms, lock) => client.getCrossChainState(terms, false, lock),
    htlc: (terms, lock) => client.getCrossChainHTLC(terms, false, lock),
    transaction: async hash => {try {const receipt = await publicClient.getTransactionReceipt({hash}); return receipt.status === 'success' ? 'success' : 'reverted'} catch {try {await publicClient.getTransaction({hash}); return 'pending'} catch {return 'missing'}}},
    submit: async ({terms, lock, secret}) => {const hash = await client.claimCrossChain(terms, false, lock, secret); const [transaction, submittedAtBlock] = await Promise.all([publicClient.getTransaction({hash}), publicClient.getBlockNumber()]); return {hash, nonce: transaction.nonce, submittedAtBlock}},
  }
}

async function journal(workspace: string): Promise<RevealReference | undefined> {
  try { return parseReference(await readFile(join(resolve(workspace), 'journal', 'revealing-claim.json'), 'utf8')) } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') return undefined
    throw error
  }
}

export async function submitRevealingClaim(args: {readonly workspace: string; readonly configPath: string; readonly input: string; readonly boundary?: RevealingClaimBoundary; readonly onPreview?: (preview: RevealingClaimPreview) => void}): Promise<{readonly tradeId: Hex32; readonly transactionHash: Hash; readonly lifecycle: 'pending' | 'success'; readonly reused: boolean; readonly preview: RevealingClaimPreview}> {
  confirmation(args.input)
  const config = await loadConsoleRuntimeConfig(args.configPath, 'alice')
  return withWorkspaceMutation(args.workspace, async () => {
    const expected = {party: 'alice' as const, networkId: config.identity.networkId, configDigest: config.identity.digest}
    const restored = await restoreWorkspaceWorkflowState(args.workspace, expected)
    if (restored.publicState.party !== 'alice' || restored.secretState.party !== 'alice' || restored.publicState.stage !== 'bob-committed' || !restored.publicState.progression.published) throw new Error('revealing claim requires Alice to verify Bob committed')
    const observation = object(JSON.parse(await readFile(join(resolve(args.workspace), 'public', 'bob-commit-observation.json'), 'utf8')), 'Bob commit observation')
    if (observation['lifecycle'] !== 'committed' || observation['tradeId'] !== restored.publicState.tradeId || observation['aliceClaimEnabled'] !== true) throw new Error('Bob commit observation does not enable Alice claim')
    const boundary = args.boundary ?? createLocalRevealingClaimBoundary(config)
    const view = preview(config, restored.terms, await boundary.htlc(restored.terms, restored.publicState.derived.settlementLock))
    args.onPreview?.(view)
    const existing = await journal(args.workspace)
    if (existing !== undefined) {
      if (existing.networkId !== config.identity.networkId || existing.tradeId !== restored.publicState.tradeId || existing.wrapper.toLowerCase() !== config.chains[1].wrapper.toLowerCase() || existing.sender.toLowerCase() !== config.actors.alice.toLowerCase()) throw new Error('revealing-claim journal binding mismatch')
      const lifecycle = await boundary.transaction(existing.transactionHash)
      if (lifecycle === 'reverted' || lifecycle === 'missing') throw new Error(`recorded revealing claim is ${lifecycle}; observe or recover before resending`)
      await publishReference(config, existing)
      return {tradeId: restored.publicState.tradeId, transactionHash: existing.transactionHash, lifecycle, reused: true, preview: view}
    }
    if (await boundary.state(restored.terms, restored.publicState.derived.settlementLock) !== CrossChainLegState.Committed) throw new Error('Bob leg is not in the exact committed state')
    const submitted = await boundary.submit({terms: restored.terms, lock: restored.publicState.derived.settlementLock, secret: restored.secretState.settlementSecret})
    const reference: RevealReference = {networkId: config.identity.networkId, tradeId: restored.publicState.tradeId, chainId: 31338, wrapper: config.chains[1].wrapper, transactionHash: submitted.hash, sender: config.actors.alice, nonce: submitted.nonce, submittedAtBlock: submitted.submittedAtBlock.toString()}
    await writeLockedWorkspaceJournal(args.workspace, 'revealing-claim', `${JSON.stringify({schema: JOURNAL_SCHEMA, action: 'revealing-claim', ...reference}, null, 2)}\n`)
    await publishReference(config, reference)
    return {tradeId: restored.publicState.tradeId, transactionHash: submitted.hash, lifecycle: 'pending', reused: false, preview: view}
  })
}
