import {spawn, spawnSync} from 'node:child_process'
import {closeSync, constants, openSync} from 'node:fs'
import {access, chmod, mkdir, open, readFile, rm} from 'node:fs/promises'
import {dirname, join, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'
import {bootstrapDemoEnvironment, serializeDemoDeploymentArtifact} from './demo-environment.js'
import {connectChain, loadArtifact} from '../test/helpers/chain.js'

export const LOCAL_BOOTSTRAP_SCHEMA = 'quip-swap-local-bootstrap.v1' as const

export interface LocalBootstrapProfile {
  readonly schema: typeof LOCAL_BOOTSTRAP_SCHEMA
  readonly networkId: string
  readonly prototype: true
  readonly mockVerifier: true
  readonly requiredConfirmations: number
  readonly deterministicTimestamp: string
  readonly chains: readonly [
    {readonly chainId: 31337; readonly rpcUrl: string},
    {readonly chainId: 31338; readonly rpcUrl: string},
  ]
}

const sdkRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const repoRoot = join(sdkRoot, '..')

function record(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${label} must be an object`)
  return value as Record<string, unknown>
}

function localRpc<C extends 31337 | 31338>(value: unknown, chainId: C): {chainId: C; rpcUrl: string} {
  const chain = record(value, `chain ${chainId}`)
  if (chain['chainId'] !== chainId || typeof chain['rpcUrl'] !== 'string') throw new Error(`invalid chain ${chainId} bootstrap entry`)
  const url = new URL(chain['rpcUrl'])
  if (url.protocol !== 'http:' || (url.hostname !== '127.0.0.1' && url.hostname !== 'localhost') || url.username !== '' || url.password !== '') {
    throw new Error(`chain ${chainId} RPC must be unauthenticated local HTTP`)
  }
  const port = Number(url.port)
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error(`invalid chain ${chainId} RPC port`)
  return {chainId, rpcUrl: url.toString().replace(/\/$/, '')}
}

export function parseLocalBootstrapProfile(value: unknown): LocalBootstrapProfile {
  const profile = record(value, 'local bootstrap profile')
  if (profile['schema'] !== LOCAL_BOOTSTRAP_SCHEMA) throw new Error('unsupported local bootstrap schema')
  if (typeof profile['networkId'] !== 'string' || profile['networkId'].trim() === '') throw new Error('invalid local bootstrap networkId')
  if (profile['prototype'] !== true || profile['mockVerifier'] !== true) throw new Error('local bootstrap must explicitly enable prototype and mock verifier')
  if (!Number.isSafeInteger(profile['requiredConfirmations']) || (profile['requiredConfirmations'] as number) < 1) throw new Error('invalid required confirmations')
  if (typeof profile['deterministicTimestamp'] !== 'string' || !/^[0-9]+$/.test(profile['deterministicTimestamp']) || BigInt(profile['deterministicTimestamp']) <= 0n) throw new Error('invalid deterministic timestamp')
  if (!Array.isArray(profile['chains']) || profile['chains'].length !== 2) throw new Error('local bootstrap requires exactly two chains')
  const chains = [localRpc(profile['chains'][0], 31337), localRpc(profile['chains'][1], 31338)] as const
  if (chains[0].rpcUrl === chains[1].rpcUrl) throw new Error('local bootstrap chains require distinct RPC endpoints')
  return {
    schema: LOCAL_BOOTSTRAP_SCHEMA,
    networkId: profile['networkId'],
    prototype: true,
    mockVerifier: true,
    requiredConfirmations: profile['requiredConfirmations'] as number,
    deterministicTimestamp: profile['deterministicTimestamp'],
    chains,
  }
}

export async function loadLocalBootstrapProfile(path: string): Promise<LocalBootstrapProfile> {
  let value: unknown
  try { value = JSON.parse(await readFile(resolve(path), 'utf8')) } catch (error) { throw new Error('local bootstrap profile is not valid JSON', {cause: error}) }
  return parseLocalBootstrapProfile(value)
}

async function rpcChainId(rpcUrl: string): Promise<number | undefined> {
  try {
    const response = await fetch(rpcUrl, {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: []})})
    if (!response.ok) return undefined
    const body = await response.json() as {result?: string}
    return body.result === undefined ? undefined : Number.parseInt(body.result, 16)
  } catch { return undefined }
}

async function ensureAnvil(chain: LocalBootstrapProfile['chains'][number], logPath: string): Promise<number | undefined> {
  const existing = await rpcChainId(chain.rpcUrl)
  if (existing !== undefined) {
    throw new Error(`RPC ${chain.rpcUrl} is already serving chain ${existing}. Stop the previous demo using its runtime.json before running bootstrap-local again.`)
  }
  const url = new URL(chain.rpcUrl)
  const log = openSync(logPath, constants.O_CREAT | constants.O_WRONLY | constants.O_APPEND, 0o600)
  const child = spawn('anvil', ['--host', '127.0.0.1', '--port', url.port, '--chain-id', String(chain.chainId), '--silent'], {detached: true, stdio: ['ignore', log, log]})
  child.unref()
  closeSync(log)
  if (child.pid === undefined) throw new Error(`failed to start Anvil chain ${chain.chainId}`)
  const deadline = Date.now() + 30_000
  while (Date.now() < deadline) {
    if (await rpcChainId(chain.rpcUrl) === chain.chainId) return child.pid
    await new Promise(resolveDelay => setTimeout(resolveDelay, 100))
  }
  try { process.kill(child.pid, 'SIGTERM') } catch {}
  throw new Error(`Anvil chain ${chain.chainId} did not become ready`)
}

async function writeNew(path: string, contents: string): Promise<void> {
  const handle = await open(path, 'wx', 0o600)
  try { await handle.writeFile(contents, 'utf8'); await handle.sync() } finally { await handle.close() }
}

export async function bootstrapConsoleLocal(args: {readonly profile: string; readonly outputDirectory: string}): Promise<{readonly networkId: string; readonly aliceConfig: string; readonly bobConfig: string; readonly startedPids: readonly number[]}> {
  const profile = await loadLocalBootstrapProfile(args.profile)
  const outputDirectory = resolve(args.outputDirectory)
  await mkdir(outputDirectory, {recursive: true, mode: 0o700})
  await chmod(outputDirectory, 0o700)
  const aliceConfig = join(outputDirectory, 'alice.config.json')
  const bobConfig = join(outputDirectory, 'bob.config.json')
  const deploymentPath = join(outputDirectory, 'deployment.json')
  const runtimePath = join(outputDirectory, 'runtime.json')
  for (const path of [aliceConfig, bobConfig, deploymentPath, runtimePath]) {
    try { await access(path); throw new Error(`bootstrap output already exists: ${path}`) } catch (error) {
      if (error instanceof Error && error.message.startsWith('bootstrap output already exists')) throw error
    }
  }
  const anvil = spawnSync('anvil', ['--version'], {stdio: 'ignore'})
  if (anvil.status !== 0) throw new Error('anvil is unavailable')
  const build = spawnSync('forge', ['build', '--root', repoRoot, '--config-path', 'config/demo/foundry.toml'], {cwd: repoRoot, stdio: 'inherit'})
  if (build.status !== 0) throw new Error('Solidity artifact build failed')
  const startedPids: number[] = []
  try {
    for (const chain of profile.chains) {
      const pid = await ensureAnvil(chain, join(outputDirectory, `anvil-${chain.chainId}.log`))
      if (pid !== undefined) startedPids.push(pid)
    }
    const chainA = connectChain(profile.chains[0].rpcUrl, 31337)
    const chainB = connectChain(profile.chains[1].rpcUrl, 31338)
    await Promise.all([chainA.testClient.setNextBlockTimestamp({timestamp: BigInt(profile.deterministicTimestamp)}), chainB.testClient.setNextBlockTimestamp({timestamp: BigInt(profile.deterministicTimestamp)})])
    const deployment = await bootstrapDemoEnvironment(chainA, chainB, loadArtifact)
    const publicBase = {
      schema: 'quip-swap-console-config.v1',
      networkId: profile.networkId,
      prototype: true,
      mockVerifier: true,
      warning: 'LOCAL PROTOTYPE ONLY; uses a mock PQ verifier and publicly known Anvil accounts.',
      requiredConfirmations: profile.requiredConfirmations,
      deterministicDemo: true,
      chains: profile.chains,
      actors: {alice: chainA.alice.address, bob: chainB.bob.address, permissionlessExecutor: chainA.charlie.address},
      timingPolicy: {policyVersion: '1', mode: 'CrossChain', partyChainId: '31337', counterpartyChainId: '31338', partyToCounterpartyDelay: '10', counterpartyToPartyDelay: '10', timingPolicyId: deployment.chains[0].localCrossChainPolicyId},
      artifactExchange: {directory: outputDirectory},
      deployment,
    }
    await writeNew(deploymentPath, serializeDemoDeploymentArtifact(deployment))
    try {
      await writeNew(runtimePath, `${JSON.stringify({schema: 'quip-swap-local-runtime.v1', networkId: profile.networkId, chains: profile.chains, startedPids}, null, 2)}\n`)
      await writeNew(aliceConfig, `${JSON.stringify({...publicBase, localParty: 'alice'}, null, 2)}\n`)
      await writeNew(bobConfig, `${JSON.stringify({...publicBase, localParty: 'bob'}, null, 2)}\n`)
    } catch (error) {
      await rm(aliceConfig, {force: true}); await rm(bobConfig, {force: true}); await rm(deploymentPath, {force: true}); await rm(runtimePath, {force: true})
      throw error
    }
    return {networkId: profile.networkId, aliceConfig, bobConfig, startedPids}
  } catch (error) {
    for (const pid of startedPids) { try { process.kill(pid, 'SIGTERM') } catch {} }
    throw error
  }
}
