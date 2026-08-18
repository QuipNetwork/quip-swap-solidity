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
      assetSupportRegistry: '0x87809f19A53302A03380189146c1291F5f4baDe9',
      identityRegistry: '0xeEe2445807eC6eCe54EA5614C9eedeE1CD5f3c58',
      authorizationGateway: '0xeEFC2Fc5Bd8F22D865Bd5956C058301e1DC04E29',
      crossChainWrapper: '0xb25ABE97C7ff0Dd32F798f2f41b65418ad2D73Ef',
      sameChainWrapper: '0x9236D569776AAD47d661E57D5a490bEbC3798145',
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
