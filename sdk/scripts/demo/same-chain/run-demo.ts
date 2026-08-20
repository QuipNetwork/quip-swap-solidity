import {spawnSync} from 'node:child_process'
import {mkdirSync, writeFileSync} from 'node:fs'
import {dirname, join, resolve} from 'node:path'
import {connectChain, loadArtifact} from '../../../test/helpers/chain.js'
import {startAnvil} from '../../../test/helpers/anvil.js'
import {
  assertSameChainArtifactValidator,
  buildSameChainDemoArtifact,
  serializeSameChainDemoArtifact,
  validateSameChainDemoArtifact,
} from './artifact.js'
import {
  SAME_CHAIN_DEMO_CHAIN_ID,
  runSameChainDemoFoundation,
} from './demo.js'

import {repoRoot, sdkRoot} from '../../shared/paths.js'
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
  const execution = await runSameChainDemoFoundation(
    connectChain(anvil.rpcUrl, anvil.chainId),
    loadArtifact,
    message => console.log(`\x1b[32m[same-chain demo ${String(++step).padStart(2, '0')}/11] ${message}\x1b[0m`),
  )
  const artifact = buildSameChainDemoArtifact(execution)
  validateSameChainDemoArtifact(artifact)
  assertSameChainArtifactValidator(artifact)
  mkdirSync(dirname(output), {recursive: true})
  writeFileSync(output, serializeSameChainDemoArtifact(artifact), {encoding: 'utf8', mode: 0o600})
  console.log(JSON.stringify({
    schema: artifact.schema,
    mockVerifier: artifact.mockVerifier,
    chainId: artifact.deployment.chainId,
    sameChainWrapper: artifact.deployment.addresses.sameChainWrapper,
    tradeId: artifact.tradeId,
    lock: artifact.lock,
    transitions: artifact.transitions.map(transition => ({
      sequence: transition.sequence,
      action: transition.action,
      transactionHash: transition.receipt.transactionHash,
      state: `${transition.stateBefore} -> ${transition.stateAfter}`,
    })),
    negativeControls: artifact.negativeControls.length,
    recoveries: artifact.recoveries.map(recovery => recovery.outcome),
    atomicRollback: artifact.atomicRollback,
    terminalOutcome: artifact.terminalOutcome,
    secretsPersisted: false,
    artifact: output,
    nextTask: 'add full two-chain failure and recovery executions',
  }, null, 2))
} finally {
  anvil.stop()
}
