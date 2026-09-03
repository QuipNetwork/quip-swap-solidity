import {describe, expect, it} from 'vitest'
import {encodeAbiParameters, encodeEventTopics} from 'viem'
import type {Address, Log, PublicClient, WalletClient} from 'viem'
import {
  AssetType,
  SideTag,
  assetSupportRegistryAbi,
  createProtocolClient,
  crossChainWrapperAbi,
  decodeProtocolEvents,
  sameChainWrapperAbi,
  swapHTLCAbi,
  SameChainState,
} from '../../src/index.js'
import type {
  CommitAuthorizationRequest,
  Hex32,
  InitialRegistration,
  ProtocolAddresses,
  ProtocolTerms,
} from '../../src/index.js'

const address = (suffix: string): Address => `0x${suffix.padStart(40, '0')}` as Address
const addresses: ProtocolAddresses = {
  assetSupportRegistry: address('1'),
  directAuthorization: address('4'),
  crossChainWrapper: address('5'),
  sameChainWrapper: address('6'),
}
const hash = (byte: string): Hex32 => `0x${byte.repeat(64)}` as Hex32

describe('current protocol SDK surface', () => {
  it('quotes and forwards live fee separately from native escrow on every commit route', async () => {
    const sequence: string[] = []
    const writes: Array<Record<string, unknown>> = []
    const publicClient = {
      readContract: async (request: Record<string, unknown>) => {
        sequence.push(`read:${String(request['functionName'])}`)
        return 7n
      },
    } as unknown as PublicClient
    const walletClient = {
      account: {address: address('a')},
      chain: undefined,
      writeContract: async (request: Record<string, unknown>) => {
        sequence.push(`write:${String(request['functionName'])}`)
        writes.push(request)
        return hash('1')
      },
    } as unknown as WalletClient
    const client = createProtocolClient({addresses, publicClient, walletClient})
    const terms = {
      partySide: {
        assets: [
          {assetType: AssetType.Native, amount: 11n},
          {assetType: AssetType.ERC20, amount: 99n},
          {assetType: AssetType.Native, amount: 13n},
        ],
      },
      counterpartySide: {assets: [{assetType: AssetType.Native, amount: 17n}]},
    } as unknown as ProtocolTerms
    const request = {receiver: addresses.crossChainWrapper, terms, party: true} as CommitAuthorizationRequest
    const registration = {} as InitialRegistration

    await expect(client.getCommitValueQuote(request)).resolves.toEqual({
      nativeEscrow: 24n,
      commitmentFee: 7n,
      totalValue: 31n,
    })
    await client.authorizeDirectCommit(request, '0x')
    await client.authorizeWalletCommit(address('b'), request, '0x')
    await client.registerAndCommit(registration, '0x', '0x', '0x', '0x', request)

    expect(writes.map(write => [write['functionName'], write['value']])).toEqual([
      ['authorizeCommit', 31n],
      ['authorizeCommit', 31n],
      ['registerAndCommit', 31n],
    ])
    expect(sequence).toEqual([
      'read:commitmentFee',
      'read:commitmentFee',
      'write:authorizeCommit',
      'read:commitmentFee',
      'write:authorizeCommit',
      'read:commitmentFee',
      'write:registerAndCommit',
    ])
  })

  it('rejects an unknown wrapper before submitting a commit', async () => {
    const client = createProtocolClient({addresses, publicClient: {} as PublicClient})
    const request = {
      receiver: address('9'),
      terms: {partySide: {assets: []}, counterpartySide: {assets: []}},
      party: true,
    } as unknown as CommitAuthorizationRequest
    await expect(client.getCommitValueQuote(request)).rejects.toMatchObject({code: 'INVALID_COMMIT_WRAPPER'})
  })

  it('does not silently retry when the live fee changes before submission', async () => {
    let fee = 7n
    let writes = 0
    const publicClient = {
      readContract: async () => fee,
    } as unknown as PublicClient
    const walletClient = {
      account: {address: address('a')},
      chain: undefined,
      writeContract: async (request: Record<string, unknown>) => {
        writes += 1
        if (writes === 1) {
          fee = 9n
          throw new Error('IncorrectNativeAmount')
        }
        expect(request['value']).toBe(20n)
        return hash('1')
      },
    } as unknown as WalletClient
    const client = createProtocolClient({addresses, publicClient, walletClient})
    const terms = {
      partySide: {assets: [{assetType: AssetType.Native, amount: 11n}]},
      counterpartySide: {assets: []},
    } as unknown as ProtocolTerms
    const request = {receiver: addresses.crossChainWrapper, terms, party: true} as CommitAuthorizationRequest

    await expect(client.authorizeDirectCommit(request, '0x')).rejects.toMatchObject({code: 'CONTRACT_REVERT'})
    expect(writes).toBe(1)
    await expect(client.authorizeDirectCommit(request, '0x')).resolves.toBe(hash('1'))
    expect(writes).toBe(2)
  })

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

  it('submits only the selected-and-batched same-chain settlement path', async () => {
    const calls: Array<Record<string, unknown>> = []
    const walletClient = {
      account: {address: address('a')},
      chain: undefined,
      writeContract: async (request: Record<string, unknown>) => {
        calls.push(request)
        return hash('1')
      },
    } as unknown as WalletClient
    const client = createProtocolClient({addresses, publicClient: {} as PublicClient, walletClient})
    const terms = {} as ProtocolTerms
    const lock = hash('2')

    await client.selectSameChainClaim(terms, lock, hash('3'))
    await client.selectSameChainReclaim(terms, lock)
    await client.executeSameChainSettlement(terms, lock, false, 4n)

    expect(calls.map(call => [call['functionName'], call['args']])).toEqual([
      ['selectClaim', [terms, lock, hash('3')]],
      ['selectReclaim', [terms, lock]],
      ['executeSettlement', [terms, lock, false, 4n]],
    ])
  })

  it('previews pending batch progress and rejects invalid local execution', async () => {
    const htlc = address('7')
    const values: Readonly<Record<string, unknown>> = {
      state: SameChainState.ClaimPending,
      settlementProgress: [3, 1],
      htlcOf: htlc,
      nextAssetIndex: 1n,
    }
    const publicClient = {
      readContract: async (request: Record<string, unknown>) => values[request['functionName'] as string],
    } as unknown as PublicClient
    const client = createProtocolClient({addresses, publicClient})
    const terms = {
      partySide: {assets: [{}, {}], recipient: address('a'), reclaimRecipient: address('b')},
      counterpartySide: {assets: [{}, {}, {}], recipient: address('c'), reclaimRecipient: address('d')},
    } as unknown as ProtocolTerms

    await expect(client.getSameChainSettlementProgress(terms, hash('2'))).resolves.toEqual({
      expectedSides: 3,
      completedSides: 1,
    })
    await expect(client.previewSameChainSettlement(terms, hash('2'), false, 2n)).resolves.toMatchObject({
      state: SameChainState.ClaimPending,
      expectedSides: 3,
      completedSides: 1,
      side: SideTag.Counterparty,
      htlc,
      recipient: address('c'),
      nextAssetIndex: 1n,
      assetCount: 3n,
      completesSide: true,
      completesTrade: true,
    })
    await expect(client.executeSameChainSettlement(terms, hash('2'), true, 0n)).rejects.toMatchObject({
      code: 'INVALID_BATCH_SIZE',
    })
  })

  it('discovers wrapper HTLCs and reads their bound lifecycle state', async () => {
    const reads: Array<Record<string, unknown>> = []
    const htlc = address('7')
    const values: Readonly<Record<string, unknown>> = {
      htlcOf: htlc,
      predictHTLC: htlc,
      controller: addresses.crossChainWrapper,
      tradeId: hash('1'),
      lock: hash('2'),
      sideTermsHash: hash('3'),
      side: SideTag.Party,
      funded: true,
      released: false,
      nextAssetIndex: 1n,
      payoutRecipient: address('8'),
    }
    const publicClient = {
      readContract: async (request: Record<string, unknown>) => {
        reads.push(request)
        return values[request['functionName'] as string]
      },
    } as unknown as PublicClient
    const client = createProtocolClient({addresses, publicClient})
    const terms = {} as ProtocolTerms

    await expect(client.getCrossChainHTLC(terms, true, hash('2'))).resolves.toBe(htlc)
    await expect(client.predictCrossChainHTLC(terms, true, hash('2'))).resolves.toBe(htlc)
    await expect(client.getSameChainHTLC(terms, false, hash('2'))).resolves.toBe(htlc)
    await expect(client.predictSameChainHTLC(terms, false, hash('2'))).resolves.toBe(htlc)
    await expect(client.getHTLCState(htlc)).resolves.toEqual({
      controller: addresses.crossChainWrapper,
      tradeId: hash('1'),
      lock: hash('2'),
      sideTermsHash: hash('3'),
      side: SideTag.Party,
      funded: true,
      released: false,
      nextAssetIndex: 1n,
      payoutRecipient: address('8'),
    })
    expect(reads.filter(read => read['address'] === htlc)).toHaveLength(9)
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

  it('decodes wrapper HTLC creation and only explicitly scoped clone events', () => {
    const htlc = address('7')
    const tradeId = hash('1')
    const lock = hash('2')
    const wrapperLog = {
      address: addresses.crossChainWrapper,
      topics: encodeEventTopics({
        abi: crossChainWrapperAbi,
        eventName: 'HTLCCreated',
        args: {tradeId, lock, side: SideTag.Party},
      }),
      data: encodeAbiParameters([{type: 'address'}], [htlc]),
      blockNumber: 1n,
      transactionHash: hash('4'),
      logIndex: 0,
      blockHash: hash('5'),
      transactionIndex: 0,
      removed: false,
    } as Log
    const fundedLog = {
      ...wrapperLog,
      address: htlc,
      topics: encodeEventTopics({
        abi: swapHTLCAbi,
        eventName: 'Funded',
        args: {tradeId, lock, side: SideTag.Party},
      }),
      data: '0x',
      logIndex: 1,
    } as Log

    expect(decodeProtocolEvents([wrapperLog, fundedLog], addresses)).toHaveLength(1)
    expect(decodeProtocolEvents([wrapperLog, fundedLog], addresses, [], [htlc])).toMatchObject([
      {source: 'crossChainWrapper', eventName: 'HTLCCreated', args: {tradeId, lock, side: SideTag.Party, htlc}},
      {source: 'swapHTLC', eventName: 'Funded', args: {tradeId, lock, side: SideTag.Party}},
    ])
  })

  it('decodes same-chain selection and batch progress events', () => {
    const tradeId = hash('1')
    const lock = hash('2')
    const selection = {
      address: addresses.sameChainWrapper,
      topics: encodeEventTopics({abi: sameChainWrapperAbi, eventName: 'ClaimSelected', args: {tradeId, lock}}),
      data: '0x',
      blockNumber: 1n,
      transactionHash: hash('4'),
      logIndex: 0,
      blockHash: hash('5'),
      transactionIndex: 0,
      removed: false,
    } as Log
    const batch = {
      ...selection,
      topics: encodeEventTopics({
        abi: sameChainWrapperAbi,
        eventName: 'SettlementBatchExecuted',
        args: {tradeId, lock, side: SideTag.Party},
      }),
      data: encodeAbiParameters([{type: 'uint256'}, {type: 'bool'}], [2n, false]),
      logIndex: 1,
    } as Log

    expect(decodeProtocolEvents([selection, batch], addresses)).toMatchObject([
      {source: 'sameChainWrapper', eventName: 'ClaimSelected', args: {tradeId, lock}},
      {
        source: 'sameChainWrapper',
        eventName: 'SettlementBatchExecuted',
        args: {tradeId, lock, side: SideTag.Party, nextAssetIndex: 2n, complete: false},
      },
    ])
  })
})
