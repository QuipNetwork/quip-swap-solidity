import {defineConfig} from 'tsup'

/**
 * Build configuration for the publishable SDK bundle.
 *
 * Only `src/index.ts` is built: test utilities, Anvil runners, and the ABI
 * generation script are intentionally excluded from the published package.
 */
export default defineConfig({
  entry: ['src/index.ts'],
  format: ['esm'],
  dts: true,
  sourcemap: true,
  clean: true,
  target: 'es2022',
})
