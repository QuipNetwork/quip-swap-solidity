import {readFileSync} from 'node:fs'
import {join} from 'node:path'

import {describe, expect, it} from 'vitest'

import {assetSupportRegistryAbi} from '../../src/generated/assetSupportRegistryAbi.js'
import {crossChainWrapperAbi} from '../../src/generated/crossChainWrapperAbi.js'
import {directAuthorizationAbi} from '../../src/generated/directAuthorizationAbi.js'
import {omnibusAbi} from '../../src/generated/omnibusAbi.js'
import {quipWalletAbi} from '../../src/generated/quipWalletAbi.js'
import {sameChainWrapperAbi} from '../../src/generated/sameChainWrapperAbi.js'
import {swapHTLCAbi} from '../../src/generated/swapHTLCAbi.js'
import {repoRoot} from '../../scripts/shared/paths.js'

const generatedContracts = [
  ['AssetSupportRegistry', assetSupportRegistryAbi],
  ['DirectAuthorization', directAuthorizationAbi],
  ['CrossChainWrapper', crossChainWrapperAbi],
  ['SameChainWrapper', sameChainWrapperAbi],
  ['SwapHTLC', swapHTLCAbi],
  ['QuipWallet', quipWalletAbi],
  ['Omnibus', omnibusAbi],
] as const

function artifactAbi(contract: string): unknown[] {
  const path = join(repoRoot, 'out', `${contract}.sol`, `${contract}.json`)
  const artifact = JSON.parse(readFileSync(path, 'utf8')) as {abi?: unknown}
  if (!Array.isArray(artifact.abi)) throw new Error(`Artifact does not contain an ABI: ${path}`)
  return artifact.abi
}

describe('generated ABI conformance', () => {
  for (const [contract, generatedAbi] of generatedContracts) {
    it(`${contract} matches its current Foundry artifact`, () => {
      expect(generatedAbi).toEqual(artifactAbi(contract))
    })
  }

  it('wrapper ABIs expose the disabled-renunciation custom error', () => {
    for (const abi of [crossChainWrapperAbi, sameChainWrapperAbi]) {
      expect(abi).toContainEqual({type: 'error', name: 'RenounceDisabled', inputs: []})
    }
  })
})
