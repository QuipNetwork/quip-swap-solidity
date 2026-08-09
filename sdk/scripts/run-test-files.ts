import {spawnSync} from 'node:child_process'
import {readdirSync} from 'node:fs'
import {dirname, join} from 'node:path'
import {fileURLToPath} from 'node:url'

const sdkRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const directories = process.argv.slice(2)
if (directories.length === 0) throw new Error('at least one test directory is required')

const files = directories.flatMap(directory =>
  readdirSync(join(sdkRoot, directory))
    .filter(file => file.endsWith('.test.ts'))
    .sort()
    .map(file => join(directory, file)),
)

for (const file of files) {
  const result = spawnSync('bunx', ['vitest', 'run', file], {cwd: sdkRoot, stdio: 'inherit'})
  if (result.status !== 0) process.exit(result.status ?? 1)
}
