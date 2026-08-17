import {createHash} from 'node:crypto'
import {mkdir, open, readFile, rename, rm} from 'node:fs/promises'
import {basename, dirname, join, resolve} from 'node:path'
import type {ClientParty} from './cliSurface.js'
import {parseClientState, serializeClientState} from './clientState.js'
import type {ClientState} from './clientState.js'
import {serializeSecretState, validatePartyWorkflowState, validateSecretState} from './clientPersistence.js'
import type {PartySecretState, RestoredPartyWorkflowState} from './clientPersistence.js'
import type {Hex32} from './types.js'

export const WORKSPACE_SCHEMA = 'quip-swap-workspace.v1' as const
export const CONSOLE_CONFIG_SCHEMA = 'quip-swap-console-config.v1' as const

export interface ConsoleConfigIdentity {
  readonly schema: typeof CONSOLE_CONFIG_SCHEMA
  readonly networkId: string
  readonly localParty: ClientParty
  readonly digest: string
  readonly source: string
}

export interface WorkspaceManifest {
  readonly schema: typeof WORKSPACE_SCHEMA
  readonly party: ClientParty
  readonly networkId: string
  readonly configDigest: string
  readonly tradeId: Hex32 | null
  readonly generation: number
}

export interface WorkspaceExpectation {
  readonly party: ClientParty
  readonly networkId: string
  readonly configDigest: string
  readonly tradeId?: Hex32
  readonly generation?: number
}

const HEX32 = /^0x[0-9a-fA-F]{64}$/
const ADDRESS = /^0x[0-9a-fA-F]{40}$/
const generationName = (generation: number) => generation.toString(10).padStart(12, '0')

function object(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${label} must be an object`)
  return value as Record<string, unknown>
}

export async function loadConsoleConfigIdentity(path: string): Promise<ConsoleConfigIdentity> {
  const source = resolve(path)
  const bytes = await readFile(source)
  let parsed: Record<string, unknown>
  try { parsed = object(JSON.parse(bytes.toString('utf8')), 'console config') } catch (error) {
    throw new Error('console config is not valid JSON', {cause: error})
  }
  if (parsed['schema'] !== CONSOLE_CONFIG_SCHEMA) throw new Error('unsupported console config schema')
  if (typeof parsed['networkId'] !== 'string' || parsed['networkId'].trim() === '') throw new Error('invalid console networkId')
  if (parsed['localParty'] !== 'alice' && parsed['localParty'] !== 'bob') throw new Error('invalid console config party')
  if (parsed['prototype'] !== true || parsed['mockVerifier'] !== true) throw new Error('console config must identify the local mock prototype')
  if (!Number.isSafeInteger(parsed['requiredConfirmations']) || (parsed['requiredConfirmations'] as number) < 1) throw new Error('invalid console confirmation policy')
  if (!Array.isArray(parsed['chains']) || parsed['chains'].length !== 2) throw new Error('console config requires two chains')
  for (const [index, chainId] of [31337, 31338].entries()) {
    const chain = object(parsed['chains'][index], `console chain ${chainId}`)
    if (chain['chainId'] !== chainId || typeof chain['rpcUrl'] !== 'string') throw new Error(`invalid console chain ${chainId}`)
    const url = new URL(chain['rpcUrl'])
    if (url.protocol !== 'http:' || (url.hostname !== '127.0.0.1' && url.hostname !== 'localhost') || url.username !== '' || url.password !== '') throw new Error(`console chain ${chainId} is not local`)
  }
  const actors = object(parsed['actors'], 'console actors')
  for (const field of ['alice', 'bob', 'permissionlessExecutor']) if (typeof actors[field] !== 'string' || !ADDRESS.test(actors[field])) throw new Error(`invalid console actor ${field}`)
  const timing = object(parsed['timingPolicy'], 'console timing policy')
  if (timing['policyVersion'] !== '1' || timing['mode'] !== 'CrossChain' || timing['partyChainId'] !== '31337' || timing['counterpartyChainId'] !== '31338' || typeof timing['partyToCounterpartyDelay'] !== 'string' || typeof timing['counterpartyToPartyDelay'] !== 'string' || typeof timing['timingPolicyId'] !== 'string' || !HEX32.test(timing['timingPolicyId'])) throw new Error('invalid console timing policy')
  const exchange = object(parsed['artifactExchange'], 'console artifact exchange')
  if (typeof exchange['directory'] !== 'string' || exchange['directory'] === '') throw new Error('invalid artifact exchange directory')
  const deployment = object(parsed['deployment'], 'console deployment')
  if (deployment['schema'] !== 'quip-swap-demo-deployment.v1' || !Array.isArray(deployment['chains']) || deployment['chains'].length !== 2) throw new Error('invalid console deployment')
  for (const [index, chainId] of [31337, 31338].entries()) {
    const chain = object(deployment['chains'][index], `deployment chain ${chainId}`)
    if (chain['chainId'] !== chainId || typeof chain['trustedVerifier'] !== 'string' || !ADDRESS.test(chain['trustedVerifier'])) throw new Error(`invalid deployment chain ${chainId}`)
    const addresses = object(chain['addresses'], `deployment addresses ${chainId}`)
    for (const field of ['assetSupportRegistry', 'timingPolicyRegistry', 'identityRegistry', 'authorizationGateway', 'crossChainWrapper', 'sameChainWrapper']) if (typeof addresses[field] !== 'string' || !ADDRESS.test(addresses[field])) throw new Error(`invalid deployment address ${field}`)
  }
  return {schema: CONSOLE_CONFIG_SCHEMA, networkId: parsed['networkId'], localParty: parsed['localParty'], digest: `sha256:${createHash('sha256').update(bytes).digest('hex')}`, source}
}

function parseManifest(text: string): WorkspaceManifest {
  let value: Record<string, unknown>
  try { value = object(JSON.parse(text), 'workspace manifest') } catch (error) {
    throw new Error('workspace manifest is not valid JSON', {cause: error})
  }
  if (value['schema'] !== WORKSPACE_SCHEMA) throw new Error('unsupported workspace schema')
  if (value['party'] !== 'alice' && value['party'] !== 'bob') throw new Error('invalid workspace party')
  if (typeof value['networkId'] !== 'string' || value['networkId'] === '') throw new Error('invalid workspace network')
  if (typeof value['configDigest'] !== 'string' || !/^sha256:[0-9a-f]{64}$/.test(value['configDigest'])) throw new Error('invalid workspace config digest')
  if (value['tradeId'] !== null && (typeof value['tradeId'] !== 'string' || !HEX32.test(value['tradeId']))) throw new Error('invalid workspace TradeID')
  if (!Number.isSafeInteger(value['generation']) || (value['generation'] as number) < 0) throw new Error('invalid workspace generation')
  if ((value['tradeId'] === null) !== (value['generation'] === 0)) throw new Error('workspace binding is incomplete')
  return value as unknown as WorkspaceManifest
}

function validateManifest(manifest: WorkspaceManifest, expected: WorkspaceExpectation): void {
  if (manifest.party !== expected.party) throw new Error('workspace party mismatch')
  if (manifest.networkId !== expected.networkId) throw new Error('workspace network mismatch')
  if (manifest.configDigest !== expected.configDigest) throw new Error('workspace configuration mismatch')
  if (expected.tradeId !== undefined && manifest.tradeId !== expected.tradeId) throw new Error('workspace TradeID mismatch')
  if (expected.generation !== undefined && manifest.generation !== expected.generation) throw new Error('workspace generation mismatch')
}

async function atomicWrite(path: string, contents: string): Promise<void> {
  const temporary = join(dirname(path), `.${basename(path)}-${process.pid}-${Date.now()}`)
  const handle = await open(temporary, 'wx', 0o600)
  try { await handle.writeFile(contents, 'utf8'); await handle.sync() } finally { await handle.close() }
  try { await rename(temporary, path) } catch (error) { await rm(temporary, {force: true}); throw error }
}

export async function initializePartyWorkspace(args: {readonly root: string; readonly party: ClientParty; readonly config: ConsoleConfigIdentity}): Promise<WorkspaceManifest> {
  const root = resolve(args.root)
  if (args.config.localParty !== args.party) throw new Error('console configuration party does not match workspace')
  const manifest: WorkspaceManifest = {schema: WORKSPACE_SCHEMA, party: args.party, networkId: args.config.networkId, configDigest: args.config.digest, tradeId: null, generation: 0}
  try { await mkdir(root, {mode: 0o700}) } catch (error) { throw new Error('workspace path already exists or cannot be created', {cause: error}) }
  try {
    for (const directory of ['public', 'private', 'journal']) await mkdir(join(root, directory), {mode: 0o700})
    await atomicWrite(join(root, 'public', 'config.json'), await readFile(args.config.source, 'utf8'))
    await atomicWrite(join(root, 'workspace.json'), `${JSON.stringify(manifest, null, 2)}\n`)
    return manifest
  } catch (error) {
    await rm(root, {recursive: true, force: true})
    throw new Error('failed to initialize complete party workspace', {cause: error})
  }
}

export async function inspectPartyWorkspace(root: string, expected: WorkspaceExpectation): Promise<WorkspaceManifest> {
  const manifest = parseManifest(await readFile(join(resolve(root), 'workspace.json'), 'utf8'))
  validateManifest(manifest, expected)
  return manifest
}

export async function withWorkspaceMutation<T>(root: string, action: () => Promise<T>): Promise<T> {
  const lockPath = join(resolve(root), '.lock')
  let handle
  try { handle = await open(lockPath, 'wx', 0o600) } catch (error) { throw new Error('workspace is locked by another mutation', {cause: error}) }
  try {
    await handle.writeFile(`${JSON.stringify({pid: process.pid, startedAt: new Date().toISOString()})}\n`, 'utf8')
    await handle.sync()
    return await action()
  } finally {
    await handle.close()
    await rm(lockPath, {force: true})
  }
}

export async function saveWorkspaceWorkflowState(args: {readonly root: string; readonly expected: WorkspaceExpectation; readonly publicState: ClientState; readonly secretState: PartySecretState; readonly publicArtifacts?: Readonly<Record<string, string>>}): Promise<void> {
  await withWorkspaceMutation(args.root, async () => {
    const manifest = await inspectPartyWorkspace(args.root, args.expected)
    validatePartyWorkflowState(args.publicState, args.secretState)
    if (args.publicState.party !== manifest.party) throw new Error('state party does not match workspace')
    if (manifest.tradeId !== null && args.publicState.tradeId !== manifest.tradeId) throw new Error('state TradeID does not match workspace')
    if (args.publicState.generation !== manifest.generation + 1) throw new Error('state generation does not advance workspace')
    const name = generationName(args.publicState.generation)
    await atomicWrite(join(resolve(args.root), 'public', `${name}.json`), serializeClientState(args.publicState))
    await atomicWrite(join(resolve(args.root), 'private', `${name}.json`), serializeSecretState(args.secretState))
    for (const [filename, contents] of Object.entries(args.publicArtifacts ?? {})) {
      if (!/^[a-z0-9][a-z0-9.-]*\.json$/.test(filename)) throw new Error('invalid public artifact filename')
      await atomicWrite(join(resolve(args.root), 'public', filename), contents)
    }
    const next: WorkspaceManifest = {...manifest, tradeId: args.publicState.tradeId, generation: args.publicState.generation}
    await atomicWrite(join(resolve(args.root), 'workspace.json'), `${JSON.stringify(next, null, 2)}\n`)
  })
}

export async function acceptWorkspaceTrade(args: {readonly root: string; readonly expected: WorkspaceExpectation; readonly acceptance: string}): Promise<WorkspaceManifest> {
  return withWorkspaceMutation(args.root, async () => {
    const manifest = await inspectPartyWorkspace(args.root, args.expected)
    if (manifest.party !== 'bob') throw new Error('only Bob may accept a trade')
    if (manifest.tradeId === null) throw new Error('workspace has no imported offer')
    const acceptancePath = join(resolve(args.root), 'public', 'acceptance.json')
    try { await readFile(acceptancePath, 'utf8'); throw new Error('trade is already accepted') } catch (error) {
      if (error instanceof Error && error.message === 'trade is already accepted') throw error
    }
    await atomicWrite(acceptancePath, args.acceptance)
    return manifest
  })
}

export async function restoreWorkspaceWorkflowState(root: string, expected: WorkspaceExpectation): Promise<RestoredPartyWorkflowState> {
  const manifest = await inspectPartyWorkspace(root, expected)
  if (manifest.tradeId === null || manifest.generation === 0) throw new Error('workspace has no trade state')
  const name = generationName(manifest.generation)
  try {
    const publicState = parseClientState(await readFile(join(resolve(root), 'public', `${name}.json`), 'utf8'))
    const rawSecret: unknown = JSON.parse(await readFile(join(resolve(root), 'private', `${name}.json`), 'utf8'))
    validateSecretState(rawSecret)
    return validatePartyWorkflowState(publicState, rawSecret)
  } catch (error) { throw new Error('workspace state generation is incomplete or corrupt', {cause: error}) }
}
