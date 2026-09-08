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
import {SameChainState, SideTag, validateCommitPayouts} from './protocol.js'
import type {CrossChainLegState} from './protocol.js'
import {AssetType} from './types.js'
import type {Hex32} from './types.js'
import {QuipSwapError, wrapContractError} from './errors.js'

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

export interface CommitValueQuote {
  readonly nativeEscrow: bigint
  readonly commitmentFee: bigint
  readonly totalValue: bigint
}

export interface HTLCState {
  readonly controller: Address
  readonly tradeId: Hex32
  readonly lock: Hex32
  readonly sideTermsHash: Hex32
  readonly side: SideTag
  readonly funded: boolean
  readonly released: boolean
  readonly nextAssetIndex: bigint
  readonly payoutRecipient: Address
}

export interface SameChainSettlementProgress {
  readonly expectedSides: number
  readonly completedSides: number
}

export interface SameChainSettlementPreview extends SameChainSettlementProgress {
  readonly state: SameChainState
  readonly side: SideTag
  readonly htlc: Address
  readonly recipient: Address
  readonly nextAssetIndex: bigint
  readonly assetCount: bigint
  readonly maxAssets: bigint
  readonly completesSide: boolean
  readonly completesTrade: boolean
}

/**
 * Calls the configured protocol contracts. Methods returning a Hash submit a transaction;
 * callers must verify its receipt and expected events before treating the action as complete.
 * Commit methods check the configured receiver and local payout destinations, then quote the
 * live fee. They do not perform full term/timing validation or verify PQ signatures locally.
 * Callers must validate terms and policy before signing and provide token approvals from the
 * principal to the wrapper. The on-chain authorization boundary verifies signatures.
 */
export interface ProtocolClient {
  readonly addresses: ProtocolAddresses
  /**
   * Reads the current fee after receiver/payout checks and adds the signed native escrow.
   * The quote does not reserve a fee: an owner update before inclusion can make the commit revert.
   * Refresh and explicitly retry after a fee-related failure; submission methods do not auto-retry it.
   */
  getCommitValueQuote(
    request: CommitAuthorizationRequest): Promise<CommitValueQuote>
  /** Submits the exact principal authorization through DirectAuthorization with a fresh fee quote. */
  authorizeDirectCommit(
    request: CommitAuthorizationRequest,
    signature: Hex): Promise<Hash>
  /** Submits through the wallet with a fresh fee quote; the signature must use its current key-epoch envelope. */
  authorizeWalletCommit(
    wallet: Address,
    request: CommitAuthorizationRequest,
    signature: Hex,
  ): Promise<Hash>
  /**
   * Submits registration and first commit atomically on-chain. `request` supplies fee-quote inputs;
   * callers must ensure it matches the encoded commitData and the registration's bound payload.
   */
  registerAndCommit(
    registration: InitialRegistration,
    eoaSignature: Hex,
    activeProof: Hex,
    recoveryProof: Hex,
    commitData: Hex,
    request: CommitAuthorizationRequest,
  ): Promise<Hash>
  executeRegistry(
    request: RegistryOperation,
    authorization: RegistryAuthorization): Promise<Hash>
  setAssetSupport(
    assetType: AssetType,
    target: Address,
    supported: boolean): Promise<Hash>
  claimCrossChain(
    terms: ProtocolTerms,
    party: boolean,
    lock: Hex32,
    secret: Hex32): Promise<Hash>
  reclaimCrossChain(
    terms: ProtocolTerms,
    party: boolean,
    lock: Hex32): Promise<Hash>
  /** Submits irreversible claim selection, revealing the secret without paying either side yet. */
  selectSameChainClaim(
    terms: ProtocolTerms,
    lock: Hex32,
    secret: Hex32): Promise<Hash>
  /** Submits irreversible reclaim selection; each required side still needs payout execution. */
  selectSameChainReclaim(
    terms: ProtocolTerms,
    lock: Hex32): Promise<Hash>
  /**
   * Submits at most maxAssets transfers for one selected side; maxAssets must be positive.
   * Verify the receipt, then reread progress. A failed batch preserves earlier successful batches.
   */
  executeSameChainSettlement(
    terms: ProtocolTerms,
    lock: Hex32,
    party: boolean,
    maxAssets: bigint,
  ): Promise<Hash>
  isAssetSupported(
    assetType: AssetType,
    target: Address): Promise<boolean>
  getIdentity(
    eoa: Address): Promise<PQIdentity>
  getCrossChainState(
    terms: ProtocolTerms,
    party: boolean,
    lock: Hex32): Promise<CrossChainLegState>
  getSameChainState(
    terms: ProtocolTerms,
    lock: Hex32): Promise<SameChainState>
  /** Reads side bitmaps: party = 1, counterparty = 2; pending trades finish when all required bits complete. */
  getSameChainSettlementProgress(
    terms: ProtocolTerms,
    lock: Hex32): Promise<SameChainSettlementProgress>
  /** Estimates progress from current reads; it neither simulates transfers nor guarantees inclusion-time state. */
  previewSameChainSettlement(
    terms: ProtocolTerms,
    lock: Hex32,
    party: boolean,
    maxAssets: bigint,
  ): Promise<SameChainSettlementPreview>
  getCrossChainHTLC(
    terms: ProtocolTerms,
    party: boolean,
    lock: Hex32): Promise<Address>
  predictCrossChainHTLC(
    terms: ProtocolTerms,
    party: boolean,
    lock: Hex32): Promise<Address>
  getSameChainHTLC(
    terms: ProtocolTerms,
    party: boolean,
    lock: Hex32): Promise<Address>
  predictSameChainHTLC(
    terms: ProtocolTerms,
    party: boolean,
    lock: Hex32): Promise<Address>
  getHTLCState(
    htlc: Address): Promise<HTLCState>
}

/**
 * Creates a client for caller-verified addresses on the supplied clients' chain.
 * Reads need only a public client; writes need a wallet client with an account.
 * Deployment authenticity, route policy, signing, and confirmed completion remain caller responsibilities.
 */
export function createProtocolClient(
  args: CreateProtocolClientArgs): ProtocolClient {
  const {addresses, publicClient, walletClient} = args

  async function write(
    address: Address,
    abi: readonly unknown[],
    functionName: string,
    fnArgs: readonly unknown[],
    value?: bigint,
  ): Promise<Hash> {
    if (walletClient?.account === undefined) {
      throw new QuipSwapError({
        code: 'MISSING_WALLET_CLIENT',
        message: 'A wallet client with an account is required',
      })
    }

    try {
      return await walletClient.writeContract({
        address,
        abi,
        functionName,
        args: fnArgs,
        account: walletClient.account,
        chain: walletClient.chain,
        ...(value === undefined ? {} : {
          value
        }),
      } as never)
    }
    catch (error) {
      if (error instanceof QuipSwapError)
        throw error
      throw wrapContractError(error, `${functionName} on ${address}`)
    }
  }

  async function read<T>(
    address: Address,
    abi: readonly unknown[],
    functionName: string,
    fnArgs: readonly unknown[],
  ): Promise<T> {
    return publicClient.readContract({
      address,
      abi,
      functionName,
      args: fnArgs
    } as never) as Promise<T>
  }

  async function getCommitValueQuote(
    request: CommitAuthorizationRequest): Promise<CommitValueQuote> {
    const wrapper = request.receiver
    const wrapperAbi = wrapper.toLowerCase() === addresses.crossChainWrapper.toLowerCase()
      ? crossChainWrapperAbi
      : wrapper.toLowerCase() === addresses.sameChainWrapper.toLowerCase()
        ? sameChainWrapperAbi
        : undefined

    if (wrapperAbi === undefined) {
      throw new QuipSwapError({
        code: 'INVALID_COMMIT_WRAPPER',
        message: `Unknown commit wrapper ${wrapper}`
      })
    }
    validateCommitPayouts(request.terms, request.party, wrapper)

    const side = request.party ? request.terms.partySide : request.terms.counterpartySide
    const nativeEscrow = side.assets.reduce(
      (
        total,
        asset) => asset.assetType === AssetType.Native ? total + asset.amount : total,
      0n,
    )
    // Read immediately before submission. This quote is deliberately not
    // cached because the wrapper validates the owner's live fee at execution.
    const commitmentFee = await read<bigint>(wrapper, wrapperAbi, 'commitmentFee', [])

    return {
      nativeEscrow,
      commitmentFee,
      totalValue: nativeEscrow + commitmentFee
    }
  }

  return {
    addresses,
    getCommitValueQuote,
    authorizeDirectCommit: async (
      request,
      signature) => {
      const quote = await getCommitValueQuote(request)

      return await write(
        addresses.directAuthorization,
        directAuthorizationAbi,
        'authorizeCommit',
        [request, signature],
        quote.totalValue,
      )
    },
    authorizeWalletCommit: async (
      wallet,
      request,
      signature) => {
      const quote = await getCommitValueQuote(request)

      return await write(wallet, quipWalletAbi, 'authorizeCommit', [request, signature], quote.totalValue)
    },
    registerAndCommit: async (
      registration,
      eoaSignature,
      activeProof,
      recoveryProof,
      commitData,
      request) => {
      const quote = await getCommitValueQuote(request)

      return await write(
        addresses.directAuthorization,
        directAuthorizationAbi,
        'registerAndCommit',
        [registration, eoaSignature, activeProof, recoveryProof, commitData],
        quote.totalValue,
      )
    },
    executeRegistry: (
      request,
      authorization) =>
      write(addresses.directAuthorization, directAuthorizationAbi, 'execute', [request, authorization]),
    setAssetSupport: (
      assetType,
      target,
      supported) =>
      write(addresses.assetSupportRegistry, assetSupportRegistryAbi, 'setAssetSupport', [assetType, target, supported]),
    claimCrossChain: (
      terms,
      party,
      lock,
      secret) =>
      write(addresses.crossChainWrapper, crossChainWrapperAbi, 'claim', [terms, party, lock, secret]),
    reclaimCrossChain: (
      terms,
      party,
      lock) =>
      write(addresses.crossChainWrapper, crossChainWrapperAbi, 'reclaim', [terms, party, lock]),
    selectSameChainClaim: (
      terms,
      lock,
      secret) =>
      write(addresses.sameChainWrapper, sameChainWrapperAbi, 'selectClaim', [terms, lock, secret]),
    selectSameChainReclaim: (
      terms,
      lock) =>
      write(addresses.sameChainWrapper, sameChainWrapperAbi, 'selectReclaim', [terms, lock]),
    executeSameChainSettlement: async (
      terms,
      lock,
      party,
      maxAssets) => {
      if (maxAssets <= 0n) {
        throw new QuipSwapError({
          code: 'INVALID_BATCH_SIZE',
          message: 'Same-chain settlement batch size must be positive'
        })
      }

      // Outcome selection is a separate irreversible transaction; this call
      // only advances the chosen HTLC through a bounded payout batch.
      return await write(
        addresses.sameChainWrapper,
        sameChainWrapperAbi,
        'executeSettlement',
        [terms, lock, party, maxAssets],
      )
    },
    isAssetSupported: (
      assetType,
      target) =>
      read(addresses.assetSupportRegistry, assetSupportRegistryAbi, 'isSupported', [assetType, target]),
    getIdentity: eoa => read(addresses.directAuthorization, directAuthorizationAbi, 'identityOf', [eoa]),
    getCrossChainState: (
      terms,
      party,
      lock) =>
      read(addresses.crossChainWrapper, crossChainWrapperAbi, 'state', [terms, party, lock]),
    getSameChainState: (
      terms,
      lock) =>
      read(addresses.sameChainWrapper, sameChainWrapperAbi, 'state', [terms, lock]),
    getSameChainSettlementProgress: async (
      terms,
      lock) => {
      const [expectedSides, completedSides] = await read<readonly [number, number]>(
        addresses.sameChainWrapper,
        sameChainWrapperAbi,
        'settlementProgress',
        [terms, lock],
      )

      return {
        expectedSides,
        completedSides
      }
    },
    previewSameChainSettlement: async (
      terms,
      lock,
      party,
      maxAssets) => {
      if (maxAssets <= 0n) {
        throw new QuipSwapError({
          code: 'INVALID_BATCH_SIZE',
          message: 'Same-chain settlement batch size must be positive'
        })
      }

      const side = party ? SideTag.Party : SideTag.Counterparty
      const bit = party ? 1 : 2
      const [state, progress, htlc] = await Promise.all([
        read<SameChainState>(addresses.sameChainWrapper, sameChainWrapperAbi, 'state', [terms, lock]),
        read<readonly [number, number]>(
          addresses.sameChainWrapper,
          sameChainWrapperAbi,
          'settlementProgress',
          [terms, lock],
        ),
        read<Address>(addresses.sameChainWrapper, sameChainWrapperAbi, 'htlcOf', [terms, party, lock]),
      ])
      const [expectedSides, completedSides] = progress

      if (state !== SameChainState.ClaimPending && state !== SameChainState.ReclaimPending) {
        throw new QuipSwapError({
          code: 'SETTLEMENT_NOT_PENDING',
          message: `Same-chain settlement is not pending (state ${SameChainState[state] ?? state})`,
        })
      }
      if ((expectedSides & bit) === 0) {
        throw new QuipSwapError({
          code: 'UNEXPECTED_SETTLEMENT_SIDE',
          message: `The ${party ? 'party' : 'counterparty'} side is not required by the selected outcome`,
        })
      }
      if ((completedSides & bit) !== 0) {
        throw new QuipSwapError({
          code: 'SETTLEMENT_SIDE_ALREADY_COMPLETE',
          message: `The ${party ? 'party' : 'counterparty'} side is already complete`,
        })
      }

      const nextAssetIndex = await read<bigint>(htlc, swapHTLCAbi, 'nextAssetIndex', [])
      const selectedSide = party ? terms.partySide : terms.counterpartySide
      const assetCount = BigInt(selectedSide.assets.length)
      const completesSide = nextAssetIndex + maxAssets >= assetCount

      return {
        state,
        expectedSides,
        completedSides,
        side,
        htlc,
        recipient: state === SameChainState.ClaimPending ? selectedSide.recipient : selectedSide.reclaimRecipient,
        nextAssetIndex,
        assetCount,
        maxAssets,
        completesSide,
        completesTrade: completesSide && (completedSides | bit) === expectedSides,
      }
    },
    getCrossChainHTLC: (
      terms,
      party,
      lock) =>
      read(addresses.crossChainWrapper, crossChainWrapperAbi, 'htlcOf', [terms, party, lock]),
    predictCrossChainHTLC: (
      terms,
      party,
      lock) =>
      read(addresses.crossChainWrapper, crossChainWrapperAbi, 'predictHTLC', [terms, party, lock]),
    getSameChainHTLC: (
      terms,
      party,
      lock) =>
      read(addresses.sameChainWrapper, sameChainWrapperAbi, 'htlcOf', [terms, party, lock]),
    predictSameChainHTLC: (
      terms,
      party,
      lock) =>
      read(addresses.sameChainWrapper, sameChainWrapperAbi, 'predictHTLC', [terms, party, lock]),
    getHTLCState: async htlc => {
      const [controller, tradeId, lock, sideTermsHash, side, funded, released, nextAssetIndex, payoutRecipient] = await Promise.all([
        read<Address>(htlc, swapHTLCAbi, 'controller', []),
        read<Hex32>(htlc, swapHTLCAbi, 'tradeId', []),
        read<Hex32>(htlc, swapHTLCAbi, 'lock', []),
        read<Hex32>(htlc, swapHTLCAbi, 'sideTermsHash', []),
        read<SideTag>(htlc, swapHTLCAbi, 'side', []),
        read<boolean>(htlc, swapHTLCAbi, 'funded', []),
        read<boolean>(htlc, swapHTLCAbi, 'released', []),
        read<bigint>(htlc, swapHTLCAbi, 'nextAssetIndex', []),
        read<Address>(htlc, swapHTLCAbi, 'payoutRecipient', []),
      ])

      return {
        controller,
        tradeId,
        lock,
        sideTermsHash,
        side,
        funded,
        released,
        nextAssetIndex,
        payoutRecipient
      }
    },
  }
}
