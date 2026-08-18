import {spawnSync} from 'node:child_process'
import {mkdirSync, writeFileSync} from 'node:fs'
import {dirname, join, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'
import {connectChain, loadArtifact} from '../test/helpers/chain.js'
import {startAnvil} from '../test/helpers/anvil.js'
import {
  SAME_CHAIN_DEMO_CHAIN_ID,
  runSameChainDemoFoundation,
  serializeSameChainDemoFoundation,
} from './same-chain-demo.js'

const sdkRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const repoRoot = join(sdkRoot, '..')
const output = resolve(process.argv[2] ?? join(repoRoot, 'demo-artifacts', 'same-chain-demo.json'))

console.log('[same-chain demo] Building Solidity artifacts')
const build = spawnSync(
  'forge',
  ['build', '--root', repoRoot, '--config-path', 'config/demo/foundry.toml'],
  {cwd: repoRoot, stdio: 'inherit'},
)
if (build.status !== 0) process.exit(build.status ?? 1)

console.log(`[same-chain demo] Starting local chain ${SAME_CHAIN_DEMO_CHAIN_ID}`)
const anvil = await startAnvil({chainId: SAME_CHAIN_DEMO_CHAIN_ID})
try {
  let step = 0
  const artifact = await runSameChainDemoFoundation(
    connectChain(anvil.rpcUrl, anvil.chainId),
    loadArtifact,
    message => console.log(`\x1b[32m[same-chain demo ${String(++step).padStart(2, '0')}/03] ${message}\x1b[0m`),
  )
  mkdirSync(dirname(output), {recursive: true})
  writeFileSync(output, serializeSameChainDemoFoundation(artifact), {encoding: 'utf8', mode: 0o600})
  console.log(JSON.stringify({
    schema: artifact.schema,
    phase: artifact.phase,
    mockVerifier: artifact.mockVerifier,
    chainId: artifact.deployment.chainId,
    sameChainWrapper: artifact.deployment.addresses.sameChainWrapper,
    tradeId: artifact.tradeId,
    lock: artifact.lock,
    artifact: output,
    nextTask: 'fund and authorize Alice and Bob',
  }, null, 2))
} finally {
  anvil.stop()
}
