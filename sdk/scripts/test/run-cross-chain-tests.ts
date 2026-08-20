/**
 * Two-chain end-to-end test runner.
 *
 * Lifecycle (step by step):
 * 1. `forge build` at the repository root (real artifacts are deployed).
 * 2. Start TWO independent Anvil nodes on OS-assigned free ports:
 *    Chain A with chain id 31337, Chain B with chain id 31338. Ports are
 *    never hardcoded, so parallel runs cannot collide.
 * 3. Run `vitest run test/cross-chain` with both nodes' coordinates in
 *    QUIP_SDK_CHAIN_A_RPC_URL / QUIP_SDK_CHAIN_B_RPC_URL (+ chain ids).
 *    The tests deploy a full fixture on EACH chain and keep both chains'
 *    block timestamps coordinated against one shared schedule.
 * 4. ALWAYS stop BOTH nodes (finally), pass or fail, and exit with
 *    vitest's exit code.
 *
 * This suite exercises a coordinated flow across two independent EVM
 * chains — NOT atomic cross-chain execution; the interleaved schedule and
 * the taker's off-chain commitment check are what bound each side's risk.
 */
import {spawnSync} from 'node:child_process'
import {startAnvil} from '../../test/helpers/anvil.js'

import {repoRoot, sdkRoot} from '../shared/paths.js'

// 1. fresh artifacts
console.log('[cross-chain] forge build ...')
const build = spawnSync('forge', ['build', '--root', repoRoot, '--config-path', 'config/demo/foundry.toml'], {cwd: repoRoot, stdio: 'inherit'})
if (build.status !== 0) {
  console.error('[cross-chain] forge build failed; aborting')
  process.exit(build.status ?? 1)
}

// 2. two independent nodes; distinct chain ids and free ports
const chainA = await startAnvil({chainId: 31_337})
console.log(`[cross-chain] chain A ready at ${chainA.rpcUrl} (chain ${chainA.chainId})`)
let chainB
try {
  chainB = await startAnvil({chainId: 31_338})
} catch (error) {
  chainA.stop()
  throw error
}
console.log(`[cross-chain] chain B ready at ${chainB.rpcUrl} (chain ${chainB.chainId})`)

let exitCode = 1
try {
  // 3. the actual test run
  const result = spawnSync('bunx', ['vitest', 'run', 'test/cross-chain'], {
    cwd: sdkRoot,
    stdio: 'inherit',
    env: {
      ...process.env,
      QUIP_SDK_CHAIN_A_RPC_URL: chainA.rpcUrl,
      QUIP_SDK_CHAIN_A_ID: String(chainA.chainId),
      QUIP_SDK_CHAIN_B_RPC_URL: chainB.rpcUrl,
      QUIP_SDK_CHAIN_B_ID: String(chainB.chainId),
    },
  })
  exitCode = result.status ?? 1
} finally {
  // 4. teardown of BOTH nodes happens pass OR fail
  chainA.stop()
  chainB.stop()
  console.log('[cross-chain] both anvil nodes stopped')
}

process.exit(exitCode)
