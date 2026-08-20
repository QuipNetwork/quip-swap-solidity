import {dirname, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'

export const sdkRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
export const repoRoot = resolve(sdkRoot, '..')
