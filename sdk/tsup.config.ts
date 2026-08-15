import {defineConfig} from 'tsup'

/**
 * Build configuration for the publishable SDK bundle.
 *
 * Current protocol and explicitly isolated legacy entry points are built.
 */
export default defineConfig({
  entry: ['src/index.ts', 'src/legacy.ts'],
  format: ['esm'],
  dts: true,
  sourcemap: true,
  clean: true,
  target: 'es2022',
})
