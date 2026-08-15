import {spawnSync} from 'node:child_process'
import {mkdirSync, writeFileSync} from 'node:fs'
import {dirname, join, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'
import {connectChain, loadArtifact} from '../test/helpers/chain.js'
import {startAnvil} from '../test/helpers/anvil.js'
import {runFullDemo, serializeFullDemo} from './full-demo.js'

const sdkRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const repoRoot = join(sdkRoot, '..')
const output = resolve(process.argv[2] ?? join(repoRoot, 'demo-artifacts', 'full-demo.json'))
console.log('[demo] Building Solidity artifacts')
const build = spawnSync('forge', ['build', '--root', repoRoot, '--config-path', 'config/demo/foundry.toml'], {cwd: repoRoot, stdio: 'inherit'})
if (build.status !== 0) process.exit(build.status ?? 1)
console.log('[demo] Starting local chains 31337 and 31338')
const a = await startAnvil({chainId: 31_337})
let b
try { b = await startAnvil({chainId: 31_338}) } catch (error) { a.stop(); throw error }
try {
  const artifact = await runFullDemo(connectChain(a.rpcUrl, a.chainId), connectChain(b.rpcUrl, b.chainId), loadArtifact, progress => {
    const current = String(progress.step).padStart(2, '0')
    console.log(`\x1b[32m[demo ${current}/${progress.total}] ${progress.message}\x1b[0m`)
  })
  console.log('[demo] Writing demo artifact')
  mkdirSync(dirname(output), {recursive: true})
  writeFileSync(output, serializeFullDemo(artifact), {encoding: 'utf8', mode: 0o600})
  console.log(JSON.stringify({schema: artifact.schema, tradeId: artifact.tradeId, finalStates: artifact.settlementTrace.finalSnapshots.map(value => [value.chainId, value.state]), negativeControls: artifact.negativeControls.records.length, artifact: output}))
} finally {
  a.stop(); b.stop()
}
