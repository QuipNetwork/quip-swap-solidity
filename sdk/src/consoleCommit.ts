import {readFile} from 'node:fs/promises'
import {join, resolve} from 'node:path'
import {concatHex, createPublicClient, createWalletClient, defineChain, encodeAbiParameters, encodeFunctionData, http, keccak256, sliceHex, stringToHex} from 'viem'
import type {Address, Hash, Hex, PublicClient, WalletClient} from 'viem'
import {privateKeyToAccount} from 'viem/accounts'
import {applyPartyCommand} from './cliCommands.js'
import {loadConsoleRuntimeConfig, parseConsoleOffer, TRADE_ACCEPTANCE_SCHEMA} from './consoleTrade.js'
import type {ConsoleRuntimeConfig} from './consoleTrade.js'
import {CrossChainLegState, ExpectedSourceState, KeyRole, commitPayloadHash, keyPossessionDigest, registrationDigest} from './protocol.js'
import type {CommitAuthorizationRequest, InitialRegistration, ProtocolTerms} from './protocol.js'
import {createProtocolClient} from './protocolClient.js'
import {pqAuthorizationGatewayAbi} from './generated/pqAuthorizationGatewayAbi.js'
import {publishLockedWorkspaceWorkflowState, restoreWorkspaceWorkflowState, withWorkspaceMutation, writeLockedWorkspaceJournal} from './consoleWorkspace.js'
import type {Hex32} from './types.js'

export const ALICE_COMMIT_INPUT_SCHEMA = 'quip-swap-alice-commit.v1' as const
export const ALICE_COMMIT_JOURNAL_SCHEMA = 'quip-swap-transaction-journal.v1' as const
const ZERO32 = `0x${'00'.repeat(32)}` as Hex32
const ANVIL_ALICE_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' as Hex

export interface AliceCommitPreview {
  readonly chainId: 31337
  readonly wrapper: Address
  readonly principal: Address
  readonly recipient: Address
  readonly assets: readonly {readonly token: Address; readonly amount: string; readonly principalChange: string; readonly wrapperChange: string}[]
  readonly commitmentDeadline: string
  readonly claimDeadline: string
  readonly reclaimRelease: string
  readonly authorizationExpiry: string
  readonly authorizationMode: 'RegisteredDirect'
}

export interface AliceCommitBoundary {
  state(terms: ProtocolTerms, lock: Hex32): Promise<CrossChainLegState>
  transaction(hash: Hash): Promise<'pending' | 'success' | 'reverted' | 'missing'>
  submit(args: {readonly terms: ProtocolTerms; readonly lock: Hex32; readonly actionNonce: Hex32; readonly expiry: bigint; readonly payloadHash: Hex32}): Promise<Hash>
}

interface AliceCommitInput {
  readonly schema: typeof ALICE_COMMIT_INPUT_SCHEMA
  readonly confirmed: true
  readonly acceptance: {readonly schema: typeof TRADE_ACCEPTANCE_SCHEMA; readonly networkId: string; readonly tradeId: Hex32; readonly bob: Address}
}

interface AliceCommitJournal {
  readonly schema: typeof ALICE_COMMIT_JOURNAL_SCHEMA
  readonly action: 'alice-commit'
  readonly networkId: string
  readonly tradeId: Hex32
  readonly chainId: 31337
  readonly wrapper: Address
  readonly transactionHash: Hash
}

const record = (value: unknown, label: string): Record<string, unknown> => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${label} must be an object`)
  return value as Record<string, unknown>
}
const isAddress = (value: unknown): value is Address => typeof value === 'string' && /^0x[0-9a-fA-F]{40}$/.test(value)
const isHex32 = (value: unknown): value is Hex32 => typeof value === 'string' && /^0x[0-9a-fA-F]{64}$/.test(value)

function parseInput(serialized: string): AliceCommitInput {
  if (/settlementSecret|bobCommitSecret|privateKey|signature/i.test(serialized)) throw new Error('Alice commit input contains forbidden sensitive material')
  const value = record(JSON.parse(serialized), 'Alice commit input')
  const acceptance = record(value['acceptance'], 'trade acceptance')
  if (value['schema'] !== ALICE_COMMIT_INPUT_SCHEMA || value['confirmed'] !== true) throw new Error('Alice commit requires explicit confirmed=true input')
  if (acceptance['schema'] !== TRADE_ACCEPTANCE_SCHEMA || typeof acceptance['networkId'] !== 'string' || !isHex32(acceptance['tradeId']) || !isAddress(acceptance['bob'])) throw new Error('invalid Bob acceptance')
  return value as unknown as AliceCommitInput
}

function preview(config: ConsoleRuntimeConfig, terms: ProtocolTerms, expiry: string): AliceCommitPreview {
  const side = terms.partySide
  return {chainId: 31337, wrapper: config.chains[0].wrapper, principal: side.principal, recipient: side.recipient, assets: side.assets.map(asset => ({token: asset.target, amount: asset.amount.toString(), principalChange: `-${asset.amount}`, wrapperChange: `+${asset.amount}`})), commitmentDeadline: side.commitmentDeadline.toString(), claimDeadline: side.claimDeadline.toString(), reclaimRelease: side.reclaimRelease.toString(), authorizationExpiry: expiry, authorizationMode: 'RegisteredDirect'}
}

function pqKey(verifier: Address, label: string): Hex { return concatHex([verifier, keccak256(stringToHex(label))]) }
function pqSignature(key: Hex, digest: Hex32): Hex { return encodeAbiParameters([{type: 'bytes'}, {type: 'bytes32'}], [sliceHex(key, 20), digest]) }

export function createLocalAliceCommitBoundary(config: ConsoleRuntimeConfig): AliceCommitBoundary {
  const route = config.chains[0]
  const chain = defineChain({id: route.chainId, name: 'anvil-31337', nativeCurrency: {name: 'Ether', symbol: 'ETH', decimals: 18}, rpcUrls: {default: {http: [route.rpcUrl]}}})
  const account = privateKeyToAccount(ANVIL_ALICE_KEY)
  if (account.address.toLowerCase() !== config.actors.alice.toLowerCase()) throw new Error('local Alice account does not match configuration')
  const publicClient = createPublicClient({chain, transport: http(route.rpcUrl)}) as PublicClient
  const walletClient = createWalletClient({chain, transport: http(route.rpcUrl), account}) as WalletClient
  const addresses = route.addresses as unknown as Parameters<typeof createProtocolClient>[0]['addresses']
  const client = createProtocolClient({addresses, publicClient, walletClient})
  return {
    state: (terms, lock) => client.getCrossChainState(terms, true, lock),
    transaction: async hash => {
      try {
        const receipt = await publicClient.getTransactionReceipt({hash})
        return receipt.status === 'success' ? 'success' : 'reverted'
      } catch {
        try { await publicClient.getTransaction({hash}); return 'pending' } catch { return 'missing' }
      }
    },
    submit: async ({terms, lock, actionNonce, expiry, payloadHash}) => {
      const activeKey = pqKey(route.trustedVerifier, 'quip-swap-console-alice-active')
      const recoveryKey = pqKey(route.trustedVerifier, 'quip-swap-console-alice-recovery')
      const request: CommitAuthorizationRequest = {receiver: route.wrapper, terms, party: true, lock, actionNonce, bobCommitSecret: ZERO32, expiry, commitData: '0x'}
      const registration: InitialRegistration = {eoa: config.actors.alice, activePQKey: activeKey, recoveryPQKey: recoveryKey, commitTarget: route.verifier, commitPayloadHash: payloadHash, operationNonce: keccak256(concatHex([terms.timingPolicyId, actionNonce])), expiry}
      const digest = registrationDigest(31337n, addresses.identityRegistry, registration)
      const call = encodeFunctionData({abi: pqAuthorizationGatewayAbi, functionName: 'authorizeCommit', args: [request, pqSignature(activeKey, payloadHash)]})
      return client.registerAndCommit(registration, '0x', pqSignature(activeKey, keyPossessionDigest(digest, KeyRole.Active, activeKey)), pqSignature(recoveryKey, keyPossessionDigest(digest, KeyRole.Recovery, recoveryKey)), sliceHex(call, 4))
    },
  }
}

async function readJournal(workspace: string): Promise<AliceCommitJournal | undefined> {
  try {
    const value = record(JSON.parse(await readFile(join(resolve(workspace), 'journal', 'alice-commit.json'), 'utf8')), 'Alice commit journal')
    if (value['schema'] !== ALICE_COMMIT_JOURNAL_SCHEMA || value['action'] !== 'alice-commit' || typeof value['networkId'] !== 'string' || !isHex32(value['tradeId']) || value['chainId'] !== 31337 || !isAddress(value['wrapper']) || !isHex32(value['transactionHash'])) throw new Error('invalid Alice commit journal')
    return value as unknown as AliceCommitJournal
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') return undefined
    throw error
  }
}

export async function submitAliceCommit(args: {readonly workspace: string; readonly configPath: string; readonly input: string; readonly boundary?: AliceCommitBoundary; readonly onPreview?: (preview: AliceCommitPreview) => void}): Promise<{readonly tradeId: Hex32; readonly transactionHash: Hash; readonly lifecycle: 'pending' | 'success'; readonly reused: boolean; readonly preview: AliceCommitPreview}> {
  const config = await loadConsoleRuntimeConfig(args.configPath, 'alice')
  const input = parseInput(args.input)
  return withWorkspaceMutation(args.workspace, async () => {
    const expected = {party: 'alice' as const, networkId: config.identity.networkId, configDigest: config.identity.digest}
    const restored = await restoreWorkspaceWorkflowState(args.workspace, expected)
    if (restored.publicState.party !== 'alice') throw new Error('Alice commit requires Alice state')
    if (input.acceptance.networkId !== config.identity.networkId || input.acceptance.tradeId !== restored.publicState.tradeId || input.acceptance.bob.toLowerCase() !== config.actors.bob.toLowerCase()) throw new Error('Bob acceptance does not match this exact trade')
    const offer = parseConsoleOffer(await readFile(join(resolve(args.workspace), 'public', 'offer.json'), 'utf8'))
    if (offer.tradeId !== restored.publicState.tradeId) throw new Error('workspace offer TradeID mismatch')
    const view = preview(config, restored.terms, offer.authorizationEvidence.partyExpiry)
    args.onPreview?.(view)
    const boundary = args.boundary ?? createLocalAliceCommitBoundary(config)
    const existing = await readJournal(args.workspace)
    if (existing !== undefined) {
      if (existing.networkId !== config.identity.networkId || existing.tradeId !== restored.publicState.tradeId || existing.wrapper.toLowerCase() !== config.chains[0].wrapper.toLowerCase()) throw new Error('Alice commit journal binding mismatch')
      const lifecycle = await boundary.transaction(existing.transactionHash)
      if (lifecycle === 'reverted') throw new Error('recorded Alice commit reverted; refusing automatic resend')
      if (lifecycle === 'missing') throw new Error('recorded Alice commit is missing; observe or recover before resending')
      if (restored.publicState.aliceCommit.status === 'not-submitted') {
        const next = applyPartyCommand(restored.publicState, restored.secretState, {command: 'mark-alice-pending'})
        await publishLockedWorkspaceWorkflowState({root: args.workspace, expected: {...expected, tradeId: restored.publicState.tradeId, generation: restored.publicState.generation}, publicState: next.publicState, secretState: next.secretState})
      }
      return {tradeId: restored.publicState.tradeId, transactionHash: existing.transactionHash, lifecycle, reused: true, preview: view}
    }
    if (restored.publicState.aliceCommit.status !== 'not-submitted' || restored.publicState.stage !== 'prepared') throw new Error('Alice commit state cannot be submitted')
    if (await boundary.state(restored.terms, restored.publicState.derived.settlementLock) !== CrossChainLegState.Unused) throw new Error('Alice leg is already used on-chain without a tracked transaction; refusing resend')
    const expiry = BigInt(offer.authorizationEvidence.partyExpiry)
    const payloadHash = commitPayloadHash({terms: restored.terms, party: true, authorizationVerifier: config.chains[0].verifier, swapAddress: config.chains[0].wrapper, lock: restored.publicState.derived.settlementLock, expectedSourceState: ExpectedSourceState.Unused, actionNonce: offer.authorizationEvidence.partyActionNonce, expiry})
    if (payloadHash !== restored.publicState.derived.partyCommitPayloadHash) throw new Error('Alice commit authorization hash mismatch')
    const transactionHash = await boundary.submit({terms: restored.terms, lock: restored.publicState.derived.settlementLock, actionNonce: offer.authorizationEvidence.partyActionNonce, expiry, payloadHash})
    const journal: AliceCommitJournal = {schema: ALICE_COMMIT_JOURNAL_SCHEMA, action: 'alice-commit', networkId: config.identity.networkId, tradeId: restored.publicState.tradeId, chainId: 31337, wrapper: config.chains[0].wrapper, transactionHash}
    await writeLockedWorkspaceJournal(args.workspace, 'alice-commit', `${JSON.stringify(journal, null, 2)}\n`)
    const next = applyPartyCommand(restored.publicState, restored.secretState, {command: 'mark-alice-pending'})
    await publishLockedWorkspaceWorkflowState({root: args.workspace, expected: {...expected, tradeId: restored.publicState.tradeId, generation: restored.publicState.generation}, publicState: next.publicState, secretState: next.secretState})
    return {tradeId: restored.publicState.tradeId, transactionHash, lifecycle: 'pending', reused: false, preview: view}
  })
}
