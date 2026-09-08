// Import the required helpers from vitest/config.
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
  // Test value carried by this record.
  test: {
    // File parallelism value carried by this record.
    fileParallelism: false,
    // Test timeout value carried by this record.
    testTimeout: 120_000,
    // Hook timeout value carried by this record.
    hookTimeout: 120_000,
  },
})
