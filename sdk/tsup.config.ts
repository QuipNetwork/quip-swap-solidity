// Import the required helpers from tsup.
import {defineConfig} from 'tsup'

/**
 * Build configuration for the publishable SDK bundle.
 *
 * Current protocol and explicitly isolated legacy entry points are built.
 */
export default defineConfig({
  // Entry value carried by this record.
  entry: ['src/index.ts', 'src/legacy.ts', 'src/bin/quip-swap.ts'],
  // Encoding or output format selected for this result.
  format: ['esm'],
  // Dts value carried by this record.
  dts: true,
  // Sourcemap value carried by this record.
  sourcemap: true,
  // Clean value carried by this record.
  clean: true,
  // Target contract address for this entry; native asset entries use zero.
  target: 'es2022',
})
