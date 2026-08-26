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
      assetSupportRegistry: '0x9Ba57720D36d83954e5ba03185e92A918D028EDF',
      directAuthorization: '0xe5c123bbB955e82208d76114aBe4170C0E0b2F95',
      crossChainWrapper: '0x795C93561Bd9F9E30FF62aCDe821B38148229E30',
      sameChainWrapper: '0xE740Bf2De5123F801AdCf534414F039ca2e83c44',
      swapHTLC: '0x1268B3FF8C710ca5629Bb0385d84D130A8e139f9',
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
