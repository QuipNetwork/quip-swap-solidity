import {describe, expect, it} from 'vitest'
import {encodeAbiParameters, encodeEventTopics} from 'viem'
import type {Address, Log, PublicClient, WalletClient} from 'viem'
import {
  AssetType,
  assetSupportRegistryAbi,
  createProtocolClient,
  decodeProtocolEvents,
} from '../../src/index.js'
import type {ProtocolAddresses} from '../../src/index.js'

const address = (suffix: string): Address => `0x${suffix.padStart(40, '0')}` as Address
const addresses: ProtocolAddresses = {
  assetSupportRegistry: address('1'),
  directAuthorization: address('4'),
  crossChainWrapper: address('5'),
  sameChainWrapper: address('6'),
}

describe('current protocol SDK surface', () => {
  it('submits asset policy writes through the configured registry', async () => {
    const calls: unknown[] = []
    const walletClient = {
      account: {address: address('a')},
      chain: undefined,
      writeContract: async (request: unknown) => {
        calls.push(request)
        return `0x${'11'.repeat(32)}`
      },
    } as unknown as WalletClient
    const publicClient = {} as PublicClient
    const client = createProtocolClient({addresses, publicClient, walletClient})

    await client.setAssetSupport(AssetType.ERC20, address('b'), true)
    expect(calls).toHaveLength(1)
    expect(calls[0]).toMatchObject({
      address: addresses.assetSupportRegistry,
      functionName: 'setAssetSupport',
      args: [AssetType.ERC20, address('b'), true],
    })
  })

  it('reads policy support through the configured registry', async () => {
    const reads: unknown[] = []
    const publicClient = {
      readContract: async (request: unknown) => {
        reads.push(request)
        return true
      },
    } as unknown as PublicClient
    const client = createProtocolClient({addresses, publicClient})
    await expect(client.isAssetSupported(AssetType.ERC721, address('c'))).resolves.toBe(true)
    expect(reads[0]).toMatchObject({
      address: addresses.assetSupportRegistry,
      functionName: 'isSupported',
      args: [AssetType.ERC721, address('c')],
    })
  })

  it('decodes only address-scoped current protocol events', () => {
    const token = address('d')
    const topics = encodeEventTopics({
      abi: assetSupportRegistryAbi,
      eventName: 'AssetSupportUpdated',
      args: {assetType: AssetType.ERC20, target: token},
    })
    const base = {
      data: encodeAbiParameters([{type: 'bool'}], [true]),
      topics,
      blockNumber: 1n,
      transactionHash: `0x${'22'.repeat(32)}`,
      logIndex: 0,
      blockHash: `0x${'33'.repeat(32)}`,
      transactionIndex: 0,
      removed: false,
    }
    const logs = [
      {...base, address: addresses.assetSupportRegistry},
      {...base, address: address('dead')},
    ] as Log[]

    const events = decodeProtocolEvents(logs, addresses)
    expect(events).toHaveLength(1)
    expect(events[0]).toMatchObject({
      source: 'assetSupportRegistry',
      eventName: 'AssetSupportUpdated',
      args: {assetType: AssetType.ERC20, target: token, supported: true},
    })
  })
})
