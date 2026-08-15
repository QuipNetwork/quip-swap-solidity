/** Current Quip Swap protocol SDK surface. Legacy Omnibus APIs live at package/legacy. */
export {AssetType} from './types.js'
export type {Asset, Hex32} from './types.js'

export {
  AuthorizationMode,
  DelegationPolicy,
  WrapperMode,
  SideTag,
  ActionTag,
  RegistryActionTag,
  KeyRole,
  ExpectedSourceState,
  CrossChainLegState,
  SameChainState,
  wrapperMode,
  gateTerms,
  gateContextId,
  deriveCommitLock,
  tradeId,
  settlementLock,
  timingPolicyId,
  assetHash,
  commitPayloadHash,
  registrationDigest,
  registryOperationDigest,
  keyPossessionDigest,
  walletRotationDigest,
  encodeAuthorizationNonceKey,
  encodeRegistryNonceKey,
  validateCommitProgression,
  validateProtocolTerms,
} from './protocol.js'
export type {
  SideTerms,
  ProtocolTerms,
  TimingPolicy,
  CommitPayloadArgs,
  VerifiedCommitAuthorization,
  CommitAuthorizationRequest,
  InitialRegistration,
  PQIdentity,
  RegistryAuthorization,
  RegistryOperation,
} from './protocol.js'

export {TrustedCrossChainWorkflow, randomProtocolValue, submitWithFeeBumps} from './workflows/trustedCrossChain.js'
export type {
  AliceCommitStatus,
  WorkflowStage,
  SideTermsTemplate,
  WorkflowArgs,
  PreparedAuthorization,
  WorkflowStatus,
  Inclusion,
  FinalClaimExecutor,
  RetryPolicy,
} from './workflows/trustedCrossChain.js'

export {createProtocolClient} from './protocolClient.js'
export type {
  ProtocolAddresses,
  CreateProtocolClientArgs,
  ProtocolClient,
  WriteOptions,
} from './protocolClient.js'
export {decodeProtocolEvents, waitForProtocolReceipt} from './protocolEvents.js'
export type {ProtocolEventSource, ProtocolEvent} from './protocolEvents.js'

export {assetSupportRegistryAbi} from './generated/assetSupportRegistryAbi.js'
export {timingPolicyRegistryAbi} from './generated/timingPolicyRegistryAbi.js'
export {pqIdentityRegistryAbi} from './generated/pqIdentityRegistryAbi.js'
export {pqAuthorizationGatewayAbi} from './generated/pqAuthorizationGatewayAbi.js'
export {crossChainWrapperAbi} from './generated/crossChainWrapperAbi.js'
export {sameChainWrapperAbi} from './generated/sameChainWrapperAbi.js'
export {quipWalletAbi} from './generated/quipWalletAbi.js'
