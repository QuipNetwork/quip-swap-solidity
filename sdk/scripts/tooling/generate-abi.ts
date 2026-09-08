import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs'
import {join} from 'node:path'

import {sdkRoot} from '../shared/paths.js'
const generated = join(sdkRoot, 'src', 'generated')

const contracts = [
  ['AssetSupportRegistry', 'assetSupportRegistryAbi'],
  ['DirectAuthorization', 'directAuthorizationAbi'],
  ['CrossChainWrapper', 'crossChainWrapperAbi'],
  ['SameChainWrapper', 'sameChainWrapperAbi'],
  ['SwapHTLC', 'swapHTLCAbi'],
  ['QuipWallet', 'quipWalletAbi'],
  ['Omnibus', 'omnibusAbi'],
] as const

mkdirSync(generated, {
  recursive: true
})

for (const [contract, exportName] of contracts) {
  const artifactPath = join(sdkRoot, '..', 'out', `${contract}.sol`, `${contract}.json`)

  if (!existsSync(artifactPath)) {
    throw new Error(`Foundry artifact not found: ${artifactPath}. Run forge build first.`)
  }

  const artifact: unknown = JSON.parse(readFileSync(artifactPath, 'utf8'))

  if (
    typeof artifact !== 'object' || artifact === null || !('abi' in artifact)
    || !Array.isArray((artifact as {
      abi: unknown
    }).abi)
  ) {
    throw new Error(`Artifact does not contain an ABI: ${artifactPath}`)
  }

  const outputPath = join(generated, `${exportName}.ts`)
  const header =
    `/** AUTO-GENERATED from out/${contract}.sol/${contract}.json. */\n` +
    `export const ${exportName} = `

  writeFileSync(outputPath, `${header}${JSON.stringify((artifact as {
    abi: unknown[]
  }).abi, null, 2)} as const\n`)

  console.log(`Wrote ${exportName} to ${outputPath}`)
}
