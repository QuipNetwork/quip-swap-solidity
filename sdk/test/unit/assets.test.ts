/**
 * Asset builder and validation unit tests.
 *
 * Covers: canonical field rules for all four asset types, zero-amount and
 * zero-target rejection, the ERC-20 id==0 rule, ERC-721 amount
 * canonicalization, token-id-zero acceptance, invalid enum rejection,
 * immutability, and totalNative summation.
 *
 * Parallels the Foundry suites `test/TermsLib/behaviors/validateAsset.t.sol`
 * and `test/TermsLib/behaviors/totalNative.t.sol`.
 */
import {zeroAddress} from 'viem'
import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {erc1155Asset, erc20Asset, erc721Asset, nativeAsset, totalNative, validateAsset} from '../../src/assets.js'
import {QuipSwapError} from '../../src/errors.js'
import {AssetType} from '../../src/types.js'
import type {Asset} from '../../src/types.js'

const TOKEN: Address = '0x1000000000000000000000000000000000000001'

function codeOf(
  fn: () => unknown): string {
  try {
    fn()
  }
  catch (error) {
    if (error instanceof QuipSwapError)
      return error.code
    throw error
  }

  throw new Error('expected the call to throw a QuipSwapError')
}

describe('nativeAsset', () => {
  it('produces canonical fields: zero target, id 0', () => {
    const asset = nativeAsset(5n)

    expect(asset).toEqual({
      assetType: AssetType.Native,
      target: zeroAddress,
      id: 0n,
      amount: 5n
    })
  })

  it('rejects zero amount (contract: ZeroAmount)', () => {
    expect(codeOf(() => nativeAsset(0n))).toBe('ZERO_AMOUNT')
  })

  it('returns a frozen object', () => {
    const asset = nativeAsset(1n)

    expect(Object.isFrozen(asset)).toBe(true)
  })
})

describe('erc20Asset', () => {
  it('produces canonical fields: id MUST be 0n', () => {
    const asset = erc20Asset(TOKEN, 100n)

    expect(asset).toEqual({
      assetType: AssetType.ERC20,
      target: TOKEN,
      id: 0n,
      amount: 100n
    })
  })

  it('rejects zero amount', () => {
    expect(codeOf(() => erc20Asset(TOKEN, 0n))).toBe('ZERO_AMOUNT')
  })

  it('rejects zero target (contract: InvalidERC20Asset)', () => {
    expect(codeOf(() => erc20Asset(zeroAddress, 100n))).toBe('INVALID_ERC20_ASSET')
  })
})

describe('erc721Asset', () => {
  it('canonicalizes amount to 1n (SDK-STRICTER-THAN-CONTRACT)', () => {
    // the contract only enforces amount != 0, but the amount is hashed into
    // the digest while the transfer always moves exactly one NFT — the SDK
    // pins it to 1n like the repo's AssetHelper.makeERC721
    const asset = erc721Asset(TOKEN, 7n)

    expect(asset.amount).toBe(1n)
  })

  it('ACCEPTS token id zero (the contract explicitly permits it)', () => {
    expect(erc721Asset(TOKEN, 0n).id).toBe(0n)
    expect(() => validateAsset(erc721Asset(TOKEN, 0n))).not.toThrow()
  })

  it('rejects zero target (contract: InvalidERC721Asset)', () => {
    expect(codeOf(() => erc721Asset(zeroAddress, 1n))).toBe('INVALID_ERC721_ASSET')
  })
})

describe('erc1155Asset', () => {
  it('produces canonical fields', () => {
    const asset = erc1155Asset(TOKEN, 3n, 25n)

    expect(asset).toEqual({
      assetType: AssetType.ERC1155,
      target: TOKEN,
      id: 3n,
      amount: 25n
    })
  })

  it('ACCEPTS token id zero', () => {
    expect(erc1155Asset(TOKEN, 0n, 1n).id).toBe(0n)
  })

  it('rejects zero amount', () => {
    expect(codeOf(() => erc1155Asset(TOKEN, 1n, 0n))).toBe('ZERO_AMOUNT')
  })

  it('rejects zero target (contract: InvalidERC1155Asset)', () => {
    expect(codeOf(() => erc1155Asset(zeroAddress, 1n, 1n))).toBe('INVALID_ERC1155_ASSET')
  })
})

describe('validateAsset (external objects)', () => {
  it('rejects zero amount for EVERY type including ERC-721', () => {
    // the universal on-chain rule: amount > 0 regardless of type
    for (const assetType of [AssetType.Native, AssetType.ERC20, AssetType.ERC721, AssetType.ERC1155]) {
      const target = assetType === AssetType.Native ? zeroAddress : TOKEN

      expect(codeOf(() => validateAsset({
        assetType,
        target,
        id: 0n,
        amount: 0n
      }))).toBe('ZERO_AMOUNT')
    }
  })

  it('rejects native with non-zero target or non-zero id (contract: InvalidNativeAsset)', () => {
    expect(codeOf(() => validateAsset({
      assetType: AssetType.Native,
      target: TOKEN,
      id: 0n,
      amount: 1n
    }))).toBe(
      'INVALID_NATIVE_ASSET',
    )
    expect(codeOf(() => validateAsset({
      assetType: AssetType.Native,
      target: zeroAddress,
      id: 1n,
      amount: 1n
    }))).toBe(
      'INVALID_NATIVE_ASSET',
    )
  })

  it('rejects non-zero id for ERC-20 (contract: InvalidERC20Asset)', () => {
    expect(codeOf(() => validateAsset({
      assetType: AssetType.ERC20,
      target: TOKEN,
      id: 1n,
      amount: 1n
    }))).toBe(
      'INVALID_ERC20_ASSET',
    )
  })

  it('accepts a contract-valid ERC-721 with amount != 1 (validation mirrors the contract, not the builder)', () => {
    expect(() => validateAsset({
      assetType: AssetType.ERC721,
      target: TOKEN,
      id: 1n,
      amount: 5n
    })).not.toThrow()
  })

  it('rejects invalid enum values', () => {
    expect(codeOf(() => validateAsset({
      assetType: 4 as AssetType,
      target: TOKEN,
      id: 0n,
      amount: 1n
    }))).toBe(
      'INVALID_ASSET_TYPE',
    )
    expect(codeOf(() => validateAsset({
      assetType: -1 as AssetType,
      target: TOKEN,
      id: 0n,
      amount: 1n
    }))).toBe(
      'INVALID_ASSET_TYPE',
    )
  })

  it('rejects malformed target strings', () => {
    expect(
      codeOf(() => validateAsset({
        assetType: AssetType.ERC20,
        target: 'not-an-address' as Address,
        id: 0n,
        amount: 1n
      })),
    ).toBe('INVALID_ERC20_ASSET')
  })
})

describe('totalNative', () => {
  const erc20 = erc20Asset(TOKEN, 100n)

  it('returns 0n with no native assets', () => {
    expect(totalNative({
      assets: [erc20]
    })).toBe(0n)
  })

  it('returns the single native amount', () => {
    expect(totalNative({
      assets: [nativeAsset(7n)]
    })).toBe(7n)
  })

  it('sums multiple native assets', () => {
    expect(totalNative({
      assets: [nativeAsset(7n), nativeAsset(3n)]
    })).toBe(10n)
  })

  it('ignores non-native assets in a mixed list', () => {
    const assets: Asset[] = [nativeAsset(7n), erc20, erc721Asset(TOKEN, 1n), erc1155Asset(TOKEN, 1n, 5n), nativeAsset(1n)]

    expect(totalNative({
      assets
    })).toBe(8n)
  })
})
