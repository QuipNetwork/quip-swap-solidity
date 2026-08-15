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
const build = spawnSync('forge', ['build'], {cwd: repoRoot, stdio: 'inherit'})
if (build.status !== 0) process.exit(build.status ?? 1)
const a = await startAnvil({chainId: 31_337})
let b
try { b = await startAnvil({chainId: 31_338}) } catch (error) { a.stop(); throw error }
try {
  const artifact = await runFullDemo(connectChain(a.rpcUrl, a.chainId), connectChain(b.rpcUrl, b.chainId), loadArtifact)
  mkdirSync(dirname(output), {recursive: true})
  writeFileSync(output, serializeFullDemo(artifact), {encoding: 'utf8', mode: 0o600})
  console.log(JSON.stringify({schema: artifact.schema, tradeId: artifact.tradeId, finalStates: artifact.settlementTrace.finalSnapshots.map(value => [value.chainId, value.state]), negativeControls: artifact.negativeControls.records.length, artifact: output}))
} finally {
  a.stop(); b.stop()
}
