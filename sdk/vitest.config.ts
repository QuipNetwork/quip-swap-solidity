import {defineConfig} from 'vitest/config'

/**
 * Vitest configuration.
 *
 * Integration and cross-chain tests talk to live Anvil nodes whose block
 * timestamps only move forward, so those suites must not run files in
 * parallel — each file derives its swap schedule from the chain's current
 * timestamp and warps forward. Unit and mocked-client tests are pure and
 * could parallelize, but a single consistent mode keeps results
 * deterministic everywhere.
 */
export default defineConfig({
  test: {
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 120_000,
  },
})
