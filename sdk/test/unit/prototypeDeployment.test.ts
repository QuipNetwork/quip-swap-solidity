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
      assetSupportRegistry: '0x999Cbf13223e2421fAb3d16894a19E6A1DfEE12E',
      timingPolicyRegistry: '0x216B1ffa9B0b9b0075d3F452bA54418F3c7BFc6f',
      identityRegistry: '0x617f50EfC9D607d758F14221ce8f5757927A1F15',
      authorizationGateway: '0x132A36eDe5F30C9D00477d9c8181A3E8e1Ef356F',
      crossChainWrapper: '0x67F0DB16f0a61852a63c8c1771EB5440E89396D4',
      sameChainWrapper: '0x877ED96E48852fB3640c67e576B4ceC3C1C026A0',
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
