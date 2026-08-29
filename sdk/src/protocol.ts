import {encodeAbiParameters, keccak256, zeroAddress} from 'viem'
import type {Address, Hex} from 'viem'
import {assetArrayAbiParameter} from './hashing.js'
import {AssetType} from './types.js'
import type {Asset, Hex32} from './types.js'

export enum AuthorizationMode { QuipWallet, RegisteredDirect }
export enum DelegationPolicy { NotAllowed, Permissionless, SpecificDelegate }
export enum WrapperMode { CrossChain, SameChain }
export enum SideTag { Party, Counterparty }
export enum ActionTag { Commit }
export enum RegistryActionTag { RotateActive, RecoverActive, RotateRecovery, Revoke }
export enum KeyRole { Active, Recovery }
export enum ExpectedSourceState { Unused, PartyCommitted }
export enum CrossChainLegState { Unused, Committed, Claimed, Reclaimed }
export enum SameChainState {
  Unused,
  PartyCommitted,
  BothCommitted,
  ClaimPending,
  ReclaimPending,
  Claimed,
  Reclaimed,
}

export type SameChainWorkflowStage =
  | 'unused'
  | 'party-committed'
  | 'both-committed'
  | 'claim-selected'
  | 'claim-executing'
  | 'reclaim-selected'
  | 'reclaim-executing'
  | 'claimed'
  | 'reclaimed'

/** Converts contract state plus its completion bitmap into an application workflow stage. */
export function sameChainWorkflowStage(state: SameChainState, completedSides: number): SameChainWorkflowStage {
  switch (state) {
    case SameChainState.Unused: return 'unused'
    case SameChainState.PartyCommitted: return 'party-committed'
    case SameChainState.BothCommitted: return 'both-committed'
    case SameChainState.ClaimPending: return completedSides === 0 ? 'claim-selected' : 'claim-executing'
    case SameChainState.ReclaimPending: return completedSides === 0 ? 'reclaim-selected' : 'reclaim-executing'
    case SameChainState.Claimed: return 'claimed'
    case SameChainState.Reclaimed: return 'reclaimed'
  }
}

export interface SideTerms {
  readonly chainId: bigint
  readonly assets: readonly Asset[]
  readonly principal: Address
  readonly authorizationMode: AuthorizationMode
  readonly principalKeyVersion: bigint
  readonly reclaimRecipient: Address
  readonly recipient: Address
  readonly commitmentDeadline: bigint
  readonly claimDeadline: bigint
  readonly reclaimRelease: bigint
  readonly commitLock: Hex32
  readonly delegationPolicy: DelegationPolicy
  readonly delegate: Address
  readonly delegateKeyVersion: bigint
  readonly sideNonce: Hex32
}

export interface ProtocolTerms {
  readonly partySide: SideTerms
  readonly counterpartySide: SideTerms
}

export interface InitialRegistration {
  readonly eoa: Address
  readonly activePQKey: Hex
  readonly recoveryPQKey: Hex
  readonly commitTarget: Address
  readonly commitPayloadHash: Hex32
  readonly operationNonce: Hex32
  readonly expiry: bigint
}

export interface PQIdentity {
  readonly activePQKey: Hex
  readonly activeKeyVersion: bigint
  readonly recoveryPQKey: Hex
  readonly recoveryKeyVersion: bigint
  readonly active: boolean
}

export interface RegistryOperation {
  readonly action: RegistryActionTag
  readonly eoa: Address
  readonly expectedActiveKeyVersion: bigint
  readonly expectedRecoveryKeyVersion: bigint
  readonly newActivePQKey: Hex
  readonly newActiveKeyVersion: bigint
  readonly newRecoveryPQKey: Hex
  readonly newRecoveryKeyVersion: bigint
  readonly operationNonce: Hex32
  readonly expiry: bigint
  readonly recoveryAuthorized: boolean
}

export interface RegistryAuthorization {
  readonly eoaSignature: Hex
  readonly authorizingPQSignature: Hex
  readonly activeProofOfPossession: Hex
  readonly recoveryProofOfPossession: Hex
}

export interface TimingPolicy {
  readonly policyVersion: bigint
  readonly mode: WrapperMode
  readonly partyChainId: bigint
  readonly counterpartyChainId: bigint
  readonly partyToCounterpartyDelay: bigint
  readonly counterpartyToPartyDelay: bigint
}

const sideTermsComponents = [
  {name: 'chainId', type: 'uint256'}, assetArrayAbiParameter,
  {name: 'principal', type: 'address'}, {name: 'authorizationMode', type: 'uint8'},
  {name: 'principalKeyVersion', type: 'uint256'}, {name: 'reclaimRecipient', type: 'address'},
  {name: 'recipient', type: 'address'}, {name: 'commitmentDeadline', type: 'uint256'},
  {name: 'claimDeadline', type: 'uint256'}, {name: 'reclaimRelease', type: 'uint256'},
  {name: 'commitLock', type: 'bytes32'}, {name: 'delegationPolicy', type: 'uint8'},
  {name: 'delegate', type: 'address'}, {name: 'delegateKeyVersion', type: 'uint256'},
  {name: 'sideNonce', type: 'bytes32'},
] as const

const protocolTermsParameter = {name: 'terms', type: 'tuple', components: [
  {name: 'partySide', type: 'tuple', components: sideTermsComponents},
  {name: 'counterpartySide', type: 'tuple', components: sideTermsComponents},
]} as const

const domains = {
  terms: 'InterlockTerms-v1.1', gateContext: 'InterlockBobCommitGateContext-v1.1',
  bobCommitGate: 'InterlockBobCommitGate-v1.1', settlement: 'InterlockSettlementLock-v1.1', assets: 'InterlockAssets-v1.1', commit: 'InterlockCommit-v1.1',
  registration: 'InterlockRegister-v1.1', registry: 'InterlockRegistry-v1.1', possession: 'InterlockKeyPossession-v1.1', walletCommit: 'InterlockWalletCommitAuthorization-v1.1', walletRotation: 'InterlockWalletKeyRotation-v1.1',
} as const

const abiSide = (side: SideTerms) => ({...side, assets: side.assets.map(asset => ({
  assetType: asset.assetType, target: asset.target, id: asset.id, amount: asset.amount,
}))})
const abiTerms = (terms: ProtocolTerms) => ({
  partySide: abiSide(terms.partySide), counterpartySide: abiSide(terms.counterpartySide),
})

function hashTerms(domain: string, terms: ProtocolTerms): Hex32 {
  return keccak256(encodeAbiParameters([{type: 'string'}, protocolTermsParameter], [domain, abiTerms(terms)]))
}

export const wrapperMode = (terms: ProtocolTerms): WrapperMode =>
  terms.partySide.chainId === terms.counterpartySide.chainId ? WrapperMode.SameChain : WrapperMode.CrossChain

export const expectedSourceState = (party: boolean, mode: WrapperMode): ExpectedSourceState =>
  !party && mode === WrapperMode.SameChain ? ExpectedSourceState.PartyCommitted : ExpectedSourceState.Unused

export const tradeId = (terms: ProtocolTerms): Hex32 => hashTerms(domains.terms, terms)

export function gateTerms(terms: ProtocolTerms): ProtocolTerms {
  return {...terms, counterpartySide: {...terms.counterpartySide, commitLock: `0x${'00'.repeat(32)}` as Hex32}}
}

export const gateContextId = (terms: ProtocolTerms): Hex32 => hashTerms(domains.gateContext, gateTerms(terms))

export const deriveCommitLock = (contextId: Hex32, bobCommitSecret: Hex32): Hex32 =>
  keccak256(encodeAbiParameters([{type: 'string'}, {type: 'bytes32'}, {type: 'bytes32'}],
    [domains.bobCommitGate, contextId, bobCommitSecret]))

export function validateCommitProgression(
  terms: ProtocolTerms, _party: boolean, bobCommitSecret: Hex32,
): void {
  const zero = '0x0000000000000000000000000000000000000000000000000000000000000000' as Hex32
  if (terms.partySide.commitLock !== zero) throw new Error('Invalid progression terms')

  if (wrapperMode(terms) === WrapperMode.SameChain) {
    if (terms.counterpartySide.commitLock !== zero) throw new Error('Invalid progression terms')
    if (bobCommitSecret !== zero) throw new Error('Unexpected Bob commit secret')
    return
  }

  if (terms.counterpartySide.commitLock === zero) throw new Error('Invalid progression terms')
  if (bobCommitSecret === zero) throw new Error('Missing Bob commit secret')
  if (deriveCommitLock(gateContextId(terms), bobCommitSecret) !== terms.counterpartySide.commitLock) {
    throw new Error('Invalid Bob commit secret')
  }
}

export const settlementLock = (trade: Hex32, secret: Hex32): Hex32 =>
  keccak256(encodeAbiParameters([{type: 'string'}, {type: 'bytes32'}, {type: 'bytes32'}],
    [domains.settlement, trade, secret]))

export const assetHash = (side: SideTerms): Hex32 => keccak256(encodeAbiParameters(
  [{type: 'string'}, {type: 'uint256'}, assetArrayAbiParameter],
  [domains.assets, side.chainId, abiSide(side).assets],
))

export interface CommitAuthorizationRequest {
  readonly receiver: Address
  readonly terms: ProtocolTerms
  readonly party: boolean
  readonly lock: Hex32
  readonly actionNonce: Hex32
  readonly bobCommitSecret: Hex32
  readonly expiry: bigint
  readonly commitData: Hex
}

export interface VerifiedCommitAuthorization {
  readonly payloadHash: Hex32
  readonly wrapperCaller: Address
  readonly authenticatedSubmitter: Address
  readonly authenticatedSubmitterKeyVersion: bigint
  readonly expectedSourceState: ExpectedSourceState
  readonly actionNonce: Hex32
  readonly expiry: bigint
}

export interface CommitPayloadArgs {
  readonly terms: ProtocolTerms; readonly party: boolean; readonly authorizationVerifier: Address
  readonly swapAddress: Address; readonly lock: Hex32; readonly expectedSourceState: ExpectedSourceState
  readonly actionNonce: Hex32; readonly expiry: bigint
}

export function commitPayloadHash(args: CommitPayloadArgs): Hex32 {
  const side = args.party ? args.terms.partySide : args.terms.counterpartySide
  return keccak256(encodeAbiParameters([
    {type: 'string'}, {type: 'uint256'}, {type: 'uint8'}, {type: 'address'}, {type: 'address'},
    {type: 'bytes32'}, {type: 'bytes32'}, {type: 'uint8'}, {type: 'uint8'}, {type: 'uint8'},
    {type: 'bytes32'}, {type: 'address'}, {type: 'uint256'}, {type: 'uint8'}, {type: 'address'},
    {type: 'uint256'}, {type: 'bytes32'}, {type: 'uint256'}, {type: 'uint256'},
  ], [domains.commit, side.chainId, wrapperMode(args.terms), args.authorizationVerifier, args.swapAddress,
    tradeId(args.terms), args.lock, args.party ? SideTag.Party : SideTag.Counterparty, ActionTag.Commit,
    args.expectedSourceState, assetHash(side), side.principal, side.principalKeyVersion, side.delegationPolicy,
    side.delegate, side.delegateKeyVersion, args.actionNonce, side.commitmentDeadline, args.expiry]))
}

export const encodeAuthorizationNonceKey = (
  chainId: bigint, verifier: Address, principal: Address, keyVersion: bigint, nonce: Hex32,
): Hex => encodeAbiParameters(
  [{type: 'uint256'}, {type: 'address'}, {type: 'address'}, {type: 'uint256'}, {type: 'bytes32'}],
  [chainId, verifier, principal, keyVersion, nonce],
)

export function registrationDigest(chainId: bigint, registry: Address, request: InitialRegistration): Hex32 {
  return keccak256(encodeAbiParameters([
    {type: "string"}, {type: "uint256"}, {type: "address"}, {type: "address"}, {type: "bytes32"},
    {type: "bytes32"}, {type: "address"}, {type: "bytes32"}, {type: "bytes32"}, {type: "uint256"},
  ], [domains.registration, chainId, registry, request.eoa, keccak256(request.activePQKey),
    keccak256(request.recoveryPQKey), request.commitTarget, request.commitPayloadHash, request.operationNonce, request.expiry]))
}

export function registryOperationDigest(chainId: bigint, registry: Address, request: RegistryOperation): Hex32 {
  return keccak256(encodeAbiParameters([{type: "string"}, {type: "tuple", components: [
    {name: "action", type: "uint8"}, {name: "chainId", type: "uint256"}, {name: "registry", type: "address"},
    {name: "eoa", type: "address"}, {name: "expectedActiveKeyVersion", type: "uint256"},
    {name: "expectedRecoveryKeyVersion", type: "uint256"}, {name: "newActivePQKeyHash", type: "bytes32"},
    {name: "newActiveKeyVersion", type: "uint256"}, {name: "newRecoveryPQKeyHash", type: "bytes32"},
    {name: "newRecoveryKeyVersion", type: "uint256"}, {name: "operationNonce", type: "bytes32"},
    {name: "expiry", type: "uint256"}, {name: "recoveryAuthorized", type: "bool"},
  ]}], [domains.registry, {action: request.action, chainId, registry, eoa: request.eoa,
    expectedActiveKeyVersion: request.expectedActiveKeyVersion, expectedRecoveryKeyVersion: request.expectedRecoveryKeyVersion,
    newActivePQKeyHash: keccak256(request.newActivePQKey), newActiveKeyVersion: request.newActiveKeyVersion,
    newRecoveryPQKeyHash: keccak256(request.newRecoveryPQKey), newRecoveryKeyVersion: request.newRecoveryKeyVersion,
    operationNonce: request.operationNonce, expiry: request.expiry, recoveryAuthorized: request.recoveryAuthorized}]))
}

export const keyPossessionDigest = (requestDigest: Hex32, role: KeyRole, key: Hex): Hex32 =>
  keccak256(encodeAbiParameters([{type: "string"}, {type: "bytes32"}, {type: "uint8"}, {type: "bytes32"}],
    [domains.possession, requestDigest, role, keccak256(key)]))

export function walletCommitAuthorizationDigest(
  chainId: bigint, wallet: Address, walletKeyEpoch: bigint, payloadHash: Hex32,
): Hex32 {
  return keccak256(encodeAbiParameters(
    [{type: 'string'}, {type: 'uint256'}, {type: 'address'}, {type: 'uint256'}, {type: 'bytes32'}],
    [domains.walletCommit, chainId, wallet, walletKeyEpoch, payloadHash],
  ))
}

export function walletRotationDigest(
  chainId: bigint, wallet: Address, currentEpoch: bigint, currentKeyHash: Hex32,
  newKey: Hex, nonce: Hex32, expiry: bigint,
): Hex32 {
  return keccak256(encodeAbiParameters([
    {type: "string"}, {type: "uint256"}, {type: "address"}, {type: "uint256"}, {type: "bytes32"},
    {type: "uint256"}, {type: "bytes32"}, {type: "bytes32"}, {type: "uint256"},
  ], [domains.walletRotation, chainId, wallet, currentEpoch, currentKeyHash, currentEpoch + 1n,
    keccak256(newKey), nonce, expiry]))
}

export const encodeRegistryNonceKey = (
  chainId: bigint, registry: Address, eoa: Address, keyRole: number, keyVersion: bigint, nonce: Hex32,
): Hex => encodeAbiParameters(
  [{type: 'uint256'}, {type: 'address'}, {type: 'address'}, {type: 'uint8'}, {type: 'uint256'}, {type: 'bytes32'}],
  [chainId, registry, eoa, keyRole, keyVersion, nonce],
)

export function validateProtocolTerms(terms: ProtocolTerms, policy: TimingPolicy): void {
  const mode = wrapperMode(terms)
  const invalid = () => { throw new Error('Invalid protocol terms') }
  if (policy.policyVersion === 0n || terms.partySide.chainId === 0n || terms.counterpartySide.chainId === 0n ||
      terms.partySide.principal === zeroAddress || terms.counterpartySide.principal === zeroAddress ||
      policy.mode !== mode ||
      policy.partyChainId !== terms.partySide.chainId || policy.counterpartyChainId !== terms.counterpartySide.chainId) invalid()
  validateSide(terms.partySide); validateSide(terms.counterpartySide)
  if (!(terms.partySide.commitmentDeadline < terms.counterpartySide.commitmentDeadline &&
      terms.counterpartySide.commitmentDeadline < terms.partySide.claimDeadline)) invalid()
  const zero = `0x${'00'.repeat(32)}`
  if (terms.partySide.commitLock !== zero) invalid()
  if (mode === WrapperMode.SameChain) {
    if (terms.counterpartySide.commitLock !== zero || policy.partyToCounterpartyDelay !== 0n ||
        policy.counterpartyToPartyDelay !== 0n) invalid()
    const claim = terms.partySide.claimDeadline < terms.counterpartySide.claimDeadline
      ? terms.partySide.claimDeadline : terms.counterpartySide.claimDeadline
    if (claim >= terms.partySide.reclaimRelease || claim >= terms.counterpartySide.reclaimRelease) invalid()
  } else {
    if (terms.counterpartySide.commitLock === zero || policy.partyToCounterpartyDelay <= 0n ||
        policy.counterpartyToPartyDelay <= 0n ||
        terms.partySide.claimDeadline + policy.partyToCounterpartyDelay > terms.counterpartySide.reclaimRelease ||
        terms.counterpartySide.claimDeadline + policy.counterpartyToPartyDelay > terms.partySide.reclaimRelease) invalid()
  }
}

function validateSide(side: SideTerms): void {
  const invalid = () => { throw new Error('Invalid protocol side terms') }
  if (side.recipient === zeroAddress || side.reclaimRecipient === zeroAddress || side.assets.length === 0 ||
      !(side.commitmentDeadline < side.claimDeadline && side.claimDeadline < side.reclaimRelease)) invalid()
  if ((side.authorizationMode !== AuthorizationMode.QuipWallet &&
      side.authorizationMode !== AuthorizationMode.RegisteredDirect) ||
      (side.authorizationMode === AuthorizationMode.QuipWallet && side.principalKeyVersion !== 0n) ||
      (side.authorizationMode === AuthorizationMode.RegisteredDirect && side.principalKeyVersion === 0n)) invalid()
  if ((side.delegationPolicy !== DelegationPolicy.NotAllowed &&
      side.delegationPolicy !== DelegationPolicy.Permissionless &&
      side.delegationPolicy !== DelegationPolicy.SpecificDelegate) ||
      (side.delegationPolicy === DelegationPolicy.SpecificDelegate &&
      (side.delegate === zeroAddress || side.delegateKeyVersion === 0n)) ||
      (side.delegationPolicy !== DelegationPolicy.SpecificDelegate &&
      (side.delegate !== zeroAddress || side.delegateKeyVersion !== 0n))) invalid()
  for (let i = 0; i < side.assets.length; i++) {
    const asset = side.assets[i]!
    if (asset.assetType < AssetType.Native || asset.assetType > AssetType.ERC1155 || asset.amount <= 0n || (asset.assetType === 0 && (asset.target !== zeroAddress || asset.id !== 0n)) ||
        (asset.assetType === 1 && (asset.target === zeroAddress || asset.id !== 0n)) ||
        (asset.assetType === 2 && (asset.target === zeroAddress || asset.amount !== 1n)) ||
        (asset.assetType === 3 && asset.target === zeroAddress)) invalid()
    if (i > 0 && !assetIdentityLess(side.assets[i - 1]!, asset)) invalid()
  }
}

function assetIdentityLess(a: Asset, b: Asset): boolean {
  return a.assetType !== b.assetType ? a.assetType < b.assetType
    : a.target.toLowerCase() !== b.target.toLowerCase() ? BigInt(a.target) < BigInt(b.target) : a.id < b.id
}
