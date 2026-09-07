import {spawnSync} from 'node:child_process'
import {mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync} from 'node:fs'
import {createServer} from 'node:net'
import type {Server} from 'node:net'
import {tmpdir} from 'node:os'
import {dirname, join, resolve} from 'node:path'
import {parseSpawnedCliEnvelope} from './io.js'

import {repoRoot, sdkRoot} from '../../shared/paths.js'
const runtime = mkdtempSync(join(tmpdir(), 'quip-console-demo-'))
const bootstrapOutput = join(runtime, 'bootstrap')
const aliceRoot = join(runtime, 'alice')
const bobRoot = join(runtime, 'bob')
const output = resolve(process.argv[2] ?? join(repoRoot, 'demo-artifacts', 'console-demo.json'))
const referenceOutput = join(runtime, 'full-demo.json')
const cli = join(sdkRoot, 'src', 'bin', 'quip-swap.ts')
const profileTemplate = join(repoRoot, 'config', 'demo', 'console-bootstrap.json')
const profile = join(runtime, 'console-bootstrap.json')
const transitions: string[] = []

type Envelope = {readonly ok: boolean; readonly command: string; readonly tradeId?: string; readonly result?: any; readonly error?: {readonly message?: string}}

function command(name: string, party: 'alice' | 'bob', stateRoot: string, config: string, input?: string, yes = false): Envelope {
  const args = [cli, name, '--party', party, '--state-root', stateRoot, '--config', config, '--json', ...(yes ? ['--yes'] : [])]
  const result = spawnSync(process.execPath, args, {cwd: sdkRoot, encoding: 'utf8', input: input ?? '', env: {...process.env, NO_COLOR: '1'}})
  const envelope = parseSpawnedCliEnvelope(result.stdout, name, result.stderr)
  if (result.status !== 0 || !envelope.ok) throw new Error(`${name} failed: ${envelope.error?.message ?? result.stderr}`)
  transitions.push(name)
  return envelope
}

async function rpc(url: string, method: string, params: readonly unknown[] = []): Promise<any> {
  const response = await fetch(url, {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({jsonrpc: '2.0', id: 1, method, params})})
  const value = await response.json() as {result?: unknown; error?: {message: string}}
  if (value.error !== undefined) throw new Error(`${method}: ${value.error.message}`)
  return value.result
}

const json = (value: unknown) => `${JSON.stringify(value)}\n`
const read = (path: string) => readFileSync(path, 'utf8')

const listenOnFreePort = () => new Promise<Server>((resolve, reject) => {
  const server = createServer()
  server.once('error', reject)
  server.listen(0, '127.0.0.1', () => resolve(server))
})
const closeServer = (server: Server) => new Promise<void>((resolve, reject) => {
  server.close(error => error === undefined ? resolve() : reject(error))
})
const portOf = (server: Server): number => {
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('failed to allocate local demo port')
  return address.port
}
const reservations = await Promise.all([listenOnFreePort(), listenOnFreePort()])
const ports = reservations.map(portOf)
await Promise.all(reservations.map(closeServer))
const aliceRpcUrl = `http://127.0.0.1:${ports[0]}`
const bobRpcUrl = `http://127.0.0.1:${ports[1]}`
const localProfile = JSON.parse(read(profileTemplate)) as {chains: Array<{chainId: number; rpcUrl: string}>}
localProfile.chains = localProfile.chains.map((chain, index) => ({...chain, rpcUrl: index === 0 ? aliceRpcUrl : bobRpcUrl}))
writeFileSync(profile, `${JSON.stringify(localProfile, null, 2)}\n`)
let startedPids: number[] = []
let consoleResult: {tradeId: string; alice: any; bob: any; journals: readonly string[]} | undefined

try {
  const boot = command('bootstrap-local', 'alice', bootstrapOutput, profile)
  startedPids = [...boot.result.startedPids]
  const aliceConfig = String(boot.result.aliceConfig)
  const bobConfig = String(boot.result.bobConfig)
  command('init', 'alice', aliceRoot, aliceConfig)
  command('init', 'bob', bobRoot, bobConfig)

  const latest = await rpc(aliceRpcUrl, 'eth_getBlockByNumber', ['latest', false]) as {timestamp: string}
  const now = BigInt(latest.timestamp)
  const base = now + 10n
  const prepare = command('prepare-trade', 'alice', aliceRoot, aliceConfig, json({schema: 'quip-swap-prepare-trade.v1', partyCommitmentDeadline: (base + 100n).toString(), counterpartyCommitmentDeadline: (base + 200n).toString(), partyClaimDeadline: (base + 1_000n).toString(), counterpartyClaimDeadline: (base + 900n).toString(), partyReclaimRelease: (base + 1_400n).toString(), counterpartyReclaimRelease: (base + 1_300n).toString(), partyAuthorizationExpiry: (base + 500n).toString(), counterpartyAuthorizationExpiry: (base + 600n).toString()}))
  const tradeId = String(prepare.result.tradeId)
  command('import-offer', 'bob', bobRoot, bobConfig, read(join(aliceRoot, 'public', 'offer.json')))
  command('accept-trade', 'bob', bobRoot, bobConfig)
  command('submit-alice-commit', 'alice', aliceRoot, aliceConfig, json({schema: 'quip-swap-alice-commit.v1', confirmed: true}))
  command('observe-alice-commit', 'alice', aliceRoot, aliceConfig)
  command('observe-alice-commit', 'bob', bobRoot, bobConfig)
  await rpc(aliceRpcUrl, 'anvil_mine', ['0x2'])
  command('observe-alice-commit', 'alice', aliceRoot, aliceConfig)
  command('observe-alice-commit', 'bob', bobRoot, bobConfig)
  command('submit-bob-commit', 'bob', bobRoot, bobConfig, undefined, true)
  command('observe-bob-commit', 'bob', bobRoot, bobConfig)
  command('observe-bob-commit', 'alice', aliceRoot, aliceConfig)
  command('submit-revealing-claim', 'alice', aliceRoot, aliceConfig, undefined, true)
  command('observe-reveal', 'bob', bobRoot, bobConfig)
  await rpc(bobRpcUrl, 'anvil_mine', ['0x2'])
  command('observe-reveal', 'bob', bobRoot, bobConfig)
  command('submit-final-claim', 'bob', bobRoot, bobConfig, undefined, true)
  const alice = command('status', 'alice', aliceRoot, aliceConfig).result
  const bob = command('status', 'bob', bobRoot, bobConfig).result
  for (const status of [alice, bob]) {
    if (!status.complete || status.outcome !== 'success' || status.legs.map((leg: any) => leg.state).join('|') !== 'Claimed|Claimed') throw new Error('console status is not terminal Claimed/Claimed')
    for (const leg of status.legs) {
      const htlc = leg.balances.find((balance: any) => balance.role === 'htlc')
      const recipient = leg.balances.find((balance: any) => balance.role === 'recipient')
      const expected = leg.chainId === 31337 ? '10000000000000000000' : '20000000000000000000'
      if (htlc?.amount !== '0' || recipient?.amount !== expected) throw new Error(`chain ${leg.chainId} terminal custody mismatch`)
    }
  }
  const journals = [join(aliceRoot, 'journal'), join(bobRoot, 'journal')].flatMap(directory => readdirSync(directory).sort().map(file => read(join(directory, file))))
  const serializedJournals = journals.join('\n')
  if (/settlementSecret|bobCommitSecret|privateKey|signature|preimage/i.test(serializedJournals)) throw new Error('ordinary transaction journal contains sensitive material')
  for (const action of ['alice-commit', 'bob-commit', 'revealing-claim', 'final-claim']) if (!serializedJournals.includes(`"action": "${action}"`)) throw new Error(`missing ${action} journal`)
  consoleResult = {tradeId, alice, bob, journals}
} finally {
  for (const pid of startedPids) {try {process.kill(pid, 'SIGTERM')} catch {}}
}

if (consoleResult === undefined) throw new Error('console demo did not complete')
const reference = spawnSync(process.execPath, ['run', 'scripts/demo/cross-chain/run-full-demo.ts', referenceOutput], {cwd: sdkRoot, encoding: 'utf8', env: process.env})
if (reference.status !== 0) throw new Error(`demo:full reference failed: ${reference.stderr}`)
const full = JSON.parse(read(referenceOutput))
if (full.tradeId !== consoleResult.tradeId) throw new Error(`TradeID mismatch: console ${consoleResult.tradeId}, demo:full ${full.tradeId}`)
const settlementActions = full.settlementTrace.transactions.map((entry: any) => entry.action)
if (settlementActions.join('|') !== 'alice-commit|bob-commit|revealing-claim|final-claim') throw new Error('demo:full settlement actions differ')
if (!full.authorizationTrace.records.every((entry: any) => entry.status === 'accepted') || full.authorizationTrace.records.map((entry: any) => entry.side).join('|') !== 'alice|bob') throw new Error('demo:full authorization decisions differ')
if (full.settlementTrace.finalSnapshots.map((entry: any) => entry.state).join('|') !== 'Claimed|Claimed') throw new Error('demo:full terminal outcome differs')

const artifact = {schema: 'quip-swap-console-demo.v1', tradeId: consoleResult.tradeId, transitions, authorizationDecisions: ['alice:accepted', 'bob:accepted'], finalStates: [[31337, 'Claimed'], [31338, 'Claimed']], terminalBalances: consoleResult.alice.legs.map((leg: any) => ({chainId: leg.chainId, balances: leg.balances})), journals: consoleResult.journals.map(text => JSON.parse(text)), fullDemoComparison: {tradeId: full.tradeId, settlementActions, authorizationDecisions: full.authorizationTrace.records.map((entry: any) => `${entry.side}:${entry.status}`), finalStates: full.settlementTrace.finalSnapshots.map((entry: any) => [entry.chainId, entry.state])}}
mkdirSync(dirname(output), {recursive: true})
writeFileSync(output, `${JSON.stringify(artifact, null, 2)}\n`, {encoding: 'utf8', mode: 0o600})
rmSync(runtime, {recursive: true, force: true})
console.log(JSON.stringify({schema: artifact.schema, tradeId: artifact.tradeId, finalStates: artifact.finalStates, commands: transitions.length, artifact: output}, null, 2))
