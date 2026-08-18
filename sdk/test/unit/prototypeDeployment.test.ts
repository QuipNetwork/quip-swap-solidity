import {getAddress} from 'viem'
import {describe, expect, it} from 'vitest'
import {
  buildPrototypeDeploymentManifest,
  CANONICAL_CREATEX,
  predictPrototypeAddresses,
  PROTOTYPE_DEPLOYMENT_VERSION,
  prototypeComponents,
  prototypeDeploymentVectorHash,
} from '../../src/index.js'

const DEPLOYER = getAddress('0x1111111111111111111111111111111111111111')
const OWNER = getAddress('0x2222222222222222222222222222222222222222')
const VERIFIER = getAddress('0x3333333333333333333333333333333333333333')

describe('prototype deployment vectors', () => {
  it('predicts one distinct chain-independent address per component', () => {
    const first = predictPrototypeAddresses(DEPLOYER)
    const second = predictPrototypeAddresses(DEPLOYER)
    expect(second).toEqual(first)
    expect(new Set(prototypeComponents.map(component => first[component])).size).toBe(prototypeComponents.length)
    expect(first).toEqual({
      assetSupportRegistry: '0x504BA325b5e51a95b0D2225ea7feBE87120c049D',
      directAuthorization: '0x502d3c6e1790D8cEf8344b9964ea03D08dEB27dA',
      crossChainWrapper: '0xBefC4530880E8318250592F76C63007A04b04175',
      sameChainWrapper: '0x5aa0Ef5b07cdc3FA4c7587e220AB4880df066387',
    })
  })

  it('builds a self-verifying manifest that binds chain and trust configuration', () => {
    const manifest = buildPrototypeDeploymentManifest({
      chainId: 84_532n,
      deployer: DEPLOYER,
      owner: OWNER,
      trustedVerifier: VERIFIER,
    })
    expect(manifest.version).toBe(PROTOTYPE_DEPLOYMENT_VERSION)
    expect(manifest.createX).toBe(CANONICAL_CREATEX)
    expect(manifest.vectorHash).toBe(
      prototypeDeploymentVectorHash(
        manifest.chainId,
        manifest.createX,
        manifest.deployer,
        manifest.owner,
        manifest.trustedVerifier,
        manifest.addresses,
      ),
    )
    const otherChain = buildPrototypeDeploymentManifest({...manifest, chainId: 11_155_420n})
    expect(otherChain.addresses).toEqual(manifest.addresses)
    expect(otherChain.vectorHash).not.toBe(manifest.vectorHash)
  })
})
