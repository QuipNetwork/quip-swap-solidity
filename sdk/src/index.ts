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
export {
  BASE_SEPOLIA_CHAIN_ID,
  OP_SEPOLIA_CHAIN_ID,
  PROTOTYPE_FINAL_CLAIM_DELAY,
  BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY,
  OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY,
  BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY_ID,
  OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY_ID,
} from './prototypeTiming.js'
export {
  PROTOTYPE_OPERATING_PROFILE,
  PROTOTYPE_RETRY_POLICY,
  prototypeConfirmations,
} from './prototypeOperations.js'
export type {
  PrototypeChainOperatingProfile,
  PrototypeOperatingProfile,
} from './prototypeOperations.js'
export {
  PROTOTYPE_DEPLOYMENT_VERSION,
  CANONICAL_CREATEX,
  prototypeComponents,
  predictPrototypeAddresses,
  prototypeDeploymentVectorHash,
  buildPrototypeDeploymentManifest,
} from './prototypeDeployment.js'
export type {
  PrototypeComponent,
  PrototypeDeploymentAddresses,
  PrototypeDeploymentManifest,
} from './prototypeDeployment.js'
export {
  CLI_SCHEMA_VERSION,
  cliCommandSpecs,
  cliCommandSpec,
  cliSuccess,
  cliFailure,
} from './cliSurface.js'
export type {
  ClientParty,
  CliCommand,
  CliCommandSpec,
  CliJson,
  CliSuccessOutput,
  CliFailureOutput,
  CliOutput,
} from './cliSurface.js'
export {
  CLIENT_STATE_SCHEMA,
  persistProtocolTerms,
  serializeClientState,
  parseClientState,
  clientStatesEqual,
  validateClientState,
} from './clientState.js'
export type {
  PersistedAsset,
  PersistedSideTerms,
  PersistedProtocolTerms,
  PersistedInclusion,
  AliceClientState,
  BobClientState,
  ClientState,
} from './clientState.js'

export {assetSupportRegistryAbi} from './generated/assetSupportRegistryAbi.js'
export {timingPolicyRegistryAbi} from './generated/timingPolicyRegistryAbi.js'
export {pqIdentityRegistryAbi} from './generated/pqIdentityRegistryAbi.js'
export {pqAuthorizationGatewayAbi} from './generated/pqAuthorizationGatewayAbi.js'
export {crossChainWrapperAbi} from './generated/crossChainWrapperAbi.js'
export {sameChainWrapperAbi} from './generated/sameChainWrapperAbi.js'
export {quipWalletAbi} from './generated/quipWalletAbi.js'
