import {spawnSync} from 'node:child_process'
import {mkdirSync, writeFileSync} from 'node:fs'
import {dirname, join, resolve} from 'node:path'
import {connectChain, loadArtifact} from '../../../test/helpers/chain.js'
import {startAnvil} from '../../../test/helpers/anvil.js'
import {runCrossChainRecoveryDemo, serializeCrossChainRecoveryArtifact} from './recovery-demo.js'

import {repoRoot, sdkRoot} from '../../shared/paths.js'
const output = resolve(process.argv[2] ?? join(repoRoot, 'demo-artifacts', 'cross-chain-recovery-demo.json'))
console.log('[recovery-demo] Building Solidity artifacts')
const build = spawnSync('forge', ['build', '--root', repoRoot], {
  cwd: repoRoot,
  stdio: 'inherit'
})
if (build.status !== 0)
  process.exit(build.status ?? 1)
console.log('[recovery-demo] Starting local chains 31337 and 31338')
const a = await startAnvil({
  chainId: 31_337
})
let b
try {
  b = await startAnvil({
    chainId: 31_338
  })
}
catch (error) {
  a.stop();

  throw error
}
try {
  const artifact = await runCrossChainRecoveryDemo(connectChain(a.rpcUrl, a.chainId), connectChain(b.rpcUrl, b.chainId), loadArtifact, progress => {
    const current = String(progress.step).padStart(2, '0')

    console.log(`\x1b[32m[recovery-demo ${current}/${progress.total}] ${progress.message}\x1b[0m`)
  })

  console.log('[recovery-demo] Writing redacted recovery artifact')
  mkdirSync(dirname(output), {
    recursive: true
  })

  writeFileSync(output, serializeCrossChainRecoveryArtifact(artifact), {
    encoding: 'utf8',
    mode: 0o600
  })

  console.log(JSON.stringify({
    schema: artifact.schema,
    tradeId: artifact.tradeId,
    outcomes: artifact.outcomes.map(value => ({
      scenario: value.scenario,
      states: value.finalStates.map(state => [state.chainId, state.state])
    })),
    nonFinalObservationsRejected: artifact.observations.filter(value => value.lifecycle !== 'final' && !value.advanced).length,
    artifact: output,
  }, null, 2))
} finally {
  a.stop()
  b.stop()
}
