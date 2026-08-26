import type {Address, Hash, Hex, PublicClient, WalletClient} from 'viem'
import {assetSupportRegistryAbi} from './generated/assetSupportRegistryAbi.js'
import {crossChainWrapperAbi} from './generated/crossChainWrapperAbi.js'
import {directAuthorizationAbi} from './generated/directAuthorizationAbi.js'
import {quipWalletAbi} from './generated/quipWalletAbi.js'
import {sameChainWrapperAbi} from './generated/sameChainWrapperAbi.js'
import {swapHTLCAbi} from './generated/swapHTLCAbi.js'
import type {
  CommitAuthorizationRequest,
  InitialRegistration,
  PQIdentity,
  ProtocolTerms,
  RegistryAuthorization,
  RegistryOperation,
} from './protocol.js'
import type {CrossChainLegState, SameChainState} from './protocol.js'
import type {SideTag} from './protocol.js'
import type {AssetType} from './types.js'
import type {Hex32} from './types.js'

export interface ProtocolAddresses {
  readonly assetSupportRegistry: Address
  readonly directAuthorization: Address
  readonly crossChainWrapper: Address
  readonly sameChainWrapper: Address
}

export interface CreateProtocolClientArgs {
  readonly addresses: ProtocolAddresses
  readonly publicClient: PublicClient
  readonly walletClient?: WalletClient
}

export interface WriteOptions {
  readonly value?: bigint
}

export interface HTLCState {
  readonly controller: Address
  readonly tradeId: Hex32
  readonly lock: Hex32
  readonly sideTermsHash: Hex32
  readonly side: SideTag
  readonly funded: boolean
  readonly released: boolean
}

export interface ProtocolClient {
  readonly addresses: ProtocolAddresses
  authorizeDirectCommit(request: CommitAuthorizationRequest, signature: Hex, options?: WriteOptions): Promise<Hash>
  authorizeWalletCommit(
    wallet: Address,
    request: CommitAuthorizationRequest,
    signature: Hex,
    options?: WriteOptions,
  ): Promise<Hash>
  registerAndCommit(
    registration: InitialRegistration,
    eoaSignature: Hex,
    activeProof: Hex,
    recoveryProof: Hex,
    commitData: Hex,
    options?: WriteOptions,
  ): Promise<Hash>
  executeRegistry(request: RegistryOperation, authorization: RegistryAuthorization): Promise<Hash>
  setAssetSupport(assetType: AssetType, target: Address, supported: boolean): Promise<Hash>
  claimCrossChain(terms: ProtocolTerms, party: boolean, lock: Hex32, secret: Hex32): Promise<Hash>
  reclaimCrossChain(terms: ProtocolTerms, party: boolean, lock: Hex32): Promise<Hash>
  claimSameChain(terms: ProtocolTerms, lock: Hex32, secret: Hex32): Promise<Hash>
  reclaimSameChainParty(terms: ProtocolTerms, lock: Hex32): Promise<Hash>
  reclaimSameChainBoth(terms: ProtocolTerms, lock: Hex32): Promise<Hash>
  isAssetSupported(assetType: AssetType, target: Address): Promise<boolean>
  getIdentity(eoa: Address): Promise<PQIdentity>
  getCrossChainState(terms: ProtocolTerms, party: boolean, lock: Hex32): Promise<CrossChainLegState>
  getSameChainState(terms: ProtocolTerms, lock: Hex32): Promise<SameChainState>
  getCrossChainHTLC(terms: ProtocolTerms, party: boolean, lock: Hex32): Promise<Address>
  predictCrossChainHTLC(terms: ProtocolTerms, party: boolean, lock: Hex32): Promise<Address>
  getSameChainHTLC(terms: ProtocolTerms, party: boolean, lock: Hex32): Promise<Address>
  predictSameChainHTLC(terms: ProtocolTerms, party: boolean, lock: Hex32): Promise<Address>
  getHTLCState(htlc: Address): Promise<HTLCState>
}

export function createProtocolClient(args: CreateProtocolClientArgs): ProtocolClient {
  const {addresses, publicClient, walletClient} = args

  async function write(
    address: Address,
    abi: readonly unknown[],
    functionName: string,
    fnArgs: readonly unknown[],
    value?: bigint,
  ): Promise<Hash> {
    if (walletClient?.account === undefined) throw new Error('A wallet client with an account is required')
    return walletClient.writeContract({
      address,
      abi,
      functionName,
      args: fnArgs,
      account: walletClient.account,
      chain: walletClient.chain,
      ...(value === undefined ? {} : {value}),
    } as never)
  }

  async function read<T>(
    address: Address,
    abi: readonly unknown[],
    functionName: string,
    fnArgs: readonly unknown[],
  ): Promise<T> {
    return publicClient.readContract({address, abi, functionName, args: fnArgs} as never) as Promise<T>
  }

  return {
    addresses,
    authorizeDirectCommit: (request, signature, options) =>
      write(addresses.directAuthorization, directAuthorizationAbi, 'authorizeCommit', [request, signature], options?.value),
    authorizeWalletCommit: (wallet, request, signature, options) =>
      write(wallet, quipWalletAbi, 'authorizeCommit', [request, signature], options?.value),
    registerAndCommit: (registration, eoaSignature, activeProof, recoveryProof, commitData, options) =>
      write(addresses.directAuthorization, directAuthorizationAbi, 'registerAndCommit',
        [registration, eoaSignature, activeProof, recoveryProof, commitData], options?.value),
    executeRegistry: (request, authorization) =>
      write(addresses.directAuthorization, directAuthorizationAbi, 'execute', [request, authorization]),
    setAssetSupport: (assetType, target, supported) =>
      write(addresses.assetSupportRegistry, assetSupportRegistryAbi, 'setAssetSupport', [assetType, target, supported]),
    claimCrossChain: (terms, party, lock, secret) =>
      write(addresses.crossChainWrapper, crossChainWrapperAbi, 'claim', [terms, party, lock, secret]),
    reclaimCrossChain: (terms, party, lock) =>
      write(addresses.crossChainWrapper, crossChainWrapperAbi, 'reclaim', [terms, party, lock]),
    claimSameChain: (terms, lock, secret) =>
      write(addresses.sameChainWrapper, sameChainWrapperAbi, 'claim', [terms, lock, secret]),
    reclaimSameChainParty: (terms, lock) =>
      write(addresses.sameChainWrapper, sameChainWrapperAbi, 'reclaimParty', [terms, lock]),
    reclaimSameChainBoth: (terms, lock) =>
      write(addresses.sameChainWrapper, sameChainWrapperAbi, 'reclaimBoth', [terms, lock]),
    isAssetSupported: (assetType, target) =>
      read(addresses.assetSupportRegistry, assetSupportRegistryAbi, 'isSupported', [assetType, target]),
    getIdentity: eoa => read(addresses.directAuthorization, directAuthorizationAbi, 'identityOf', [eoa]),
    getCrossChainState: (terms, party, lock) =>
      read(addresses.crossChainWrapper, crossChainWrapperAbi, 'state', [terms, party, lock]),
    getSameChainState: (terms, lock) =>
      read(addresses.sameChainWrapper, sameChainWrapperAbi, 'state', [terms, lock]),
    getCrossChainHTLC: (terms, party, lock) =>
      read(addresses.crossChainWrapper, crossChainWrapperAbi, 'htlcOf', [terms, party, lock]),
    predictCrossChainHTLC: (terms, party, lock) =>
      read(addresses.crossChainWrapper, crossChainWrapperAbi, 'predictHTLC', [terms, party, lock]),
    getSameChainHTLC: (terms, party, lock) =>
      read(addresses.sameChainWrapper, sameChainWrapperAbi, 'htlcOf', [terms, party, lock]),
    predictSameChainHTLC: (terms, party, lock) =>
      read(addresses.sameChainWrapper, sameChainWrapperAbi, 'predictHTLC', [terms, party, lock]),
    getHTLCState: async htlc => {
      const [controller, tradeId, lock, sideTermsHash, side, funded, released] = await Promise.all([
        read<Address>(htlc, swapHTLCAbi, 'controller', []),
        read<Hex32>(htlc, swapHTLCAbi, 'tradeId', []),
        read<Hex32>(htlc, swapHTLCAbi, 'lock', []),
        read<Hex32>(htlc, swapHTLCAbi, 'sideTermsHash', []),
        read<SideTag>(htlc, swapHTLCAbi, 'side', []),
        read<boolean>(htlc, swapHTLCAbi, 'funded', []),
        read<boolean>(htlc, swapHTLCAbi, 'released', []),
      ])
      return {controller, tradeId, lock, sideTermsHash, side, funded, released}
    },
  }
}
