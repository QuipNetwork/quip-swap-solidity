/**
 * Single-chain integration-test runner.
 *
 * Lifecycle (step by step):
 * 1. `forge build` at the repository root — the tests deploy real Foundry
 *    artifacts (Omnibus, mock tokens, harnesses), so the
 *    artifacts must be fresh.
 * 2. Start one Anvil node on an OS-assigned free port with chain id 31337
 *    and wait for RPC readiness (see test/helpers/anvil.ts).
 * 3. Run `vitest run test/integration` with the node's RPC URL and chain id
 *    exported via QUIP_SDK_RPC_URL / QUIP_SDK_CHAIN_ID. Each test file
 *    deploys its own fixture (Omnibus with the one-argument constructor
 *    (owner), an activated VerifierMock, mocks, harnesses) and
 *    drives block timestamps with evm_setNextBlockTimestamp + mining.
 *    Extra CLI args after `--` are forwarded to vitest (e.g.
 *    `bun run test:integration -- --reporter=verbose`).
 * 4. ALWAYS stop Anvil (finally), pass or fail, and exit with vitest's
 *    exit code.
 *
 * Developers never start Anvil manually for `bun run test:integration`.
 */
import {spawnSync} from 'node:child_process'
import {readdirSync} from 'node:fs'
import {join} from 'node:path'
import {startAnvil} from '../../test/helpers/anvil.js'

import {repoRoot, sdkRoot} from '../shared/paths.js'

/** Vitest flags/files passed after `--` (or directly to this script). */
const vitestExtraArgs = process.argv.slice(2)

// 1. fresh artifacts — fail loudly if forge is unavailable or the build breaks
console.log('[integration] forge build ...')
const build = spawnSync('forge', ['build', '--root', repoRoot], {cwd: repoRoot, stdio: 'inherit'})
if (build.status !== 0) {
  console.error('[integration] forge build failed; aborting')
  process.exit(build.status ?? 1)
}

// 2. one Anvil node on a free port
const anvil = await startAnvil({chainId: 31_337})
console.log(`[integration] anvil ready at ${anvil.rpcUrl} (chain ${anvil.chainId})`)

let exitCode = 1
try {
  // Vitest treats a positional directory as one filename filter here.
  // Enumerate files so every integration suite is executed deterministically.
  const files = readdirSync(join(sdkRoot, "test", "integration"))
    .filter(file => file.endsWith(".test.ts"))
    .sort()
    .map(file => join("test", "integration", file))
  exitCode = 0
  for (const file of files) {
    const result = spawnSync("bunx", ["vitest", "run", file, ...vitestExtraArgs], {
      cwd: sdkRoot,
      stdio: "inherit",
      env: {
        ...process.env,
        QUIP_SDK_RPC_URL: anvil.rpcUrl,
        QUIP_SDK_CHAIN_ID: String(anvil.chainId),
      },
    })
    if (result.status !== 0) {
      exitCode = result.status ?? 1
      break
    }
  }
} finally {
  // 4. teardown happens pass OR fail
  anvil.stop()
  console.log('[integration] anvil stopped')
}

process.exit(exitCode)
