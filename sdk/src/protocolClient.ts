import type {Address, Hash, Hex, PublicClient, WalletClient} from 'viem'
import {assetSupportRegistryAbi} from './generated/assetSupportRegistryAbi.js'
import {crossChainWrapperAbi} from './generated/crossChainWrapperAbi.js'
import {pqAuthorizationGatewayAbi} from './generated/pqAuthorizationGatewayAbi.js'
import {pqIdentityRegistryAbi} from './generated/pqIdentityRegistryAbi.js'
import {quipWalletAbi} from './generated/quipWalletAbi.js'
import {sameChainWrapperAbi} from './generated/sameChainWrapperAbi.js'
import {timingPolicyRegistryAbi} from './generated/timingPolicyRegistryAbi.js'
import type {
  CommitAuthorizationRequest,
  InitialRegistration,
  PQIdentity,
  ProtocolTerms,
  RegistryAuthorization,
  RegistryOperation,
  TimingPolicy,
} from './protocol.js'
import type {CrossChainLegState, SameChainState} from './protocol.js'
import type {AssetType} from './types.js'
import type {Hex32} from './types.js'

export interface ProtocolAddresses {
  readonly assetSupportRegistry: Address
  readonly timingPolicyRegistry: Address
  readonly identityRegistry: Address
  readonly authorizationGateway: Address
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
  registerTimingPolicy(expectedPolicyId: Hex32, policy: TimingPolicy): Promise<Hash>
  claimCrossChain(terms: ProtocolTerms, party: boolean, lock: Hex32, secret: Hex32): Promise<Hash>
  reclaimCrossChain(terms: ProtocolTerms, party: boolean, lock: Hex32): Promise<Hash>
  claimSameChain(terms: ProtocolTerms, lock: Hex32, secret: Hex32): Promise<Hash>
  reclaimSameChainParty(terms: ProtocolTerms, lock: Hex32): Promise<Hash>
  reclaimSameChainBoth(terms: ProtocolTerms, lock: Hex32): Promise<Hash>
  isAssetSupported(assetType: AssetType, target: Address): Promise<boolean>
  resolveTimingPolicy(policyId: Hex32): Promise<TimingPolicy>
  getIdentity(eoa: Address): Promise<PQIdentity>
  getCrossChainState(terms: ProtocolTerms, party: boolean, lock: Hex32): Promise<CrossChainLegState>
  getSameChainState(terms: ProtocolTerms, lock: Hex32): Promise<SameChainState>
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
      write(addresses.authorizationGateway, pqAuthorizationGatewayAbi, 'authorizeCommit', [request, signature], options?.value),
    authorizeWalletCommit: (wallet, request, signature, options) =>
      write(wallet, quipWalletAbi, 'authorizeCommit', [request, signature], options?.value),
    registerAndCommit: (registration, eoaSignature, activeProof, recoveryProof, commitData, options) =>
      write(addresses.identityRegistry, pqIdentityRegistryAbi, 'registerAndCommit',
        [registration, eoaSignature, activeProof, recoveryProof, commitData], options?.value),
    executeRegistry: (request, authorization) =>
      write(addresses.identityRegistry, pqIdentityRegistryAbi, 'execute', [request, authorization]),
    setAssetSupport: (assetType, target, supported) =>
      write(addresses.assetSupportRegistry, assetSupportRegistryAbi, 'setAssetSupport', [assetType, target, supported]),
    registerTimingPolicy: (expectedPolicyId, policy) =>
      write(addresses.timingPolicyRegistry, timingPolicyRegistryAbi, 'registerPolicy', [expectedPolicyId, policy]),
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
    resolveTimingPolicy: policyId =>
      read(addresses.timingPolicyRegistry, timingPolicyRegistryAbi, 'resolvePolicy', [policyId]),
    getIdentity: eoa => read(addresses.identityRegistry, pqIdentityRegistryAbi, 'identityOf', [eoa]),
    getCrossChainState: (terms, party, lock) =>
      read(addresses.crossChainWrapper, crossChainWrapperAbi, 'state', [terms, party, lock]),
    getSameChainState: (terms, lock) =>
      read(addresses.sameChainWrapper, sameChainWrapperAbi, 'state', [terms, lock]),
  }
}
