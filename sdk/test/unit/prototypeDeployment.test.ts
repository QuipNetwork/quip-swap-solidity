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
      assetSupportRegistry: '0xeAAD1bADf49D6F7D440b7951B5d3dEA16c106Add',
      directAuthorization: '0x3393579801E4CEbf80fA6F1B0D6f78EF074f3BB3',
      crossChainWrapper: '0xF9A9912FF311C99Ee47108468a8f6d60fB926a0B',
      sameChainWrapper: '0x11259234aC38CBa5a07e0fe3282535EfD65224E8',
      swapHTLC: '0x99aaDD53189eAd2Db2eB77C2A98e9745B8145930',
    })
  })

  it('builds a self-verifying manifest that binds chain and trust configuration', () => {
    const manifest = buildPrototypeDeploymentManifest({
      chainId: 84_532n,
      deployer: DEPLOYER,
      owner: OWNER,
      trustedVerifier: VERIFIER,
      finalClaimDelay: 1800n,
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
        manifest.finalClaimDelay,
      ),
    )

    const otherChain = buildPrototypeDeploymentManifest({
...manifest,
      chainId: 11_155_420n
    })

    expect(otherChain.addresses).toEqual(manifest.addresses)
    expect(otherChain.vectorHash).not.toBe(manifest.vectorHash)
    expect(buildPrototypeDeploymentManifest({
...manifest,
      finalClaimDelay: 1801n
    }).vectorHash).not.toBe(manifest.vectorHash)
    expect(() => buildPrototypeDeploymentManifest({
...manifest,
      finalClaimDelay: 0n
    })).toThrow('positive')
  })
})
