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
  expectedSourceState,
  gateTerms,
  gateContextId,
  deriveCommitLock,
  tradeId,
  settlementLock,
  assetHash,
  commitPayloadHash,
  registrationDigest,
  registryOperationDigest,
  keyPossessionDigest,
  walletCommitAuthorizationDigest,
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

export {INITIAL_WORKFLOW_LIFECYCLE, TrustedCrossChainWorkflow, prepareTrustedCrossChainWorkflow, randomProtocolValue, submitWithFeeBumps, transitionWorkflow} from './workflows/trustedCrossChain.js'
export type {
  AliceCommitStatus,
  WorkflowStage,
  SideTermsTemplate,
  WorkflowArgs,
  PreparedAuthorization,
  WorkflowStatus,
  WorkflowLifecycle,
  WorkflowEvent,
  Inclusion,
  FinalClaimExecutor,
  RetryPolicy,
  PreparedTrustedWorkflow,
  ProtocolRandomness,
} from './workflows/trustedCrossChain.js'

export {createProtocolClient} from './protocolClient.js'
export type {
  ProtocolAddresses,
  CreateProtocolClientArgs,
  ProtocolClient,
  WriteOptions,
  HTLCState,
} from './protocolClient.js'
export {decodeProtocolEvents, waitForProtocolReceipt} from './protocolEvents.js'
export type {ProtocolEventSource, ProtocolEvent} from './protocolEvents.js'
export {
  BASE_SEPOLIA_CHAIN_ID,
  OP_SEPOLIA_CHAIN_ID,
  PROTOTYPE_FINAL_CLAIM_DELAY,
  BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY,
  OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY,
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
  prototypeDeploymentSalt,
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
  CLI_EXIT_SUCCESS,
  CLI_EXIT_FAILURE,
  CLI_EXIT_USAGE,
  cliCommandSpecs,
  cliCommandSpec,
  cliSuccess,
  cliFailure,
} from './cliSurface.js'
export type {
  CliExitCode,
  ClientParty,
  CliCommand,
  CliCommandSpec,
  CliJson,
  CliSuccessOutput,
  CliFailureOutput,
  CliOutput,
} from './cliSurface.js'
export {
  CLI_NAME,
  CLI_VERSION,
  CONSOLE_CONFIRMATION_SCHEMA,
  consoleUsage,
  parseConsoleArgs,
  runConsole,
  consoleContract,
} from './consoleApp.js'
export type {ConsoleOptions, ConsoleIo, ConsoleDependencies, ConsoleParseResult} from './consoleApp.js'
export {
  WORKSPACE_SCHEMA,
  CONSOLE_CONFIG_SCHEMA,
  loadConsoleConfigIdentity,
  initializePartyWorkspace,
  inspectPartyWorkspace,
  withWorkspaceMutation,
  saveWorkspaceWorkflowState,
  restoreWorkspaceWorkflowState,
  acceptWorkspaceTrade,
  publishLockedWorkspaceWorkflowState,
  writeLockedWorkspaceJournal,
} from './consoleWorkspace.js'
export type {ConsoleConfigIdentity, WorkspaceManifest, WorkspaceExpectation} from './consoleWorkspace.js'
export {
  PREPARE_TRADE_INPUT_SCHEMA,
  PUBLIC_OFFER_SCHEMA,
  TRADE_ACCEPTANCE_SCHEMA,
  prepareConsoleTrade,
  importConsoleOffer,
  acceptConsoleTrade,
  loadConsoleRuntimeConfig,
  parseConsoleOffer,
} from './consoleTrade.js'
export type {PublicTradeOffer, ConsoleRuntimeConfig} from './consoleTrade.js'
export {
  ALICE_COMMIT_INPUT_SCHEMA,
  ALICE_COMMIT_JOURNAL_SCHEMA,
  ALICE_COMMIT_REFERENCE_SCHEMA,
  createLocalAliceCommitBoundary,
  submitAliceCommit,
} from './consoleCommit.js'
export type {AliceCommitPreview, AliceCommitBoundary} from './consoleCommit.js'
export {
  ALICE_COMMIT_OBSERVATION_SCHEMA,
  createLocalAliceObservationBoundary,
  observeAliceCommit,
} from './consoleObservation.js'
export type {AliceCommitLifecycle, AliceCommitObservation, AliceCommitObservationBoundary} from './consoleObservation.js'
export {
  BOB_COMMIT_INPUT_SCHEMA,
  BOB_COMMIT_REFERENCE_SCHEMA,
  BOB_COMMIT_OBSERVATION_SCHEMA,
  createLocalBobCommitBoundary,
  createLocalBobObservationBoundary,
  submitBobCommit,
  observeBobCommit,
} from './consoleBobCommit.js'
export type {BobCommitPreview, BobCommitBoundary, BobCommitLifecycle, BobCommitObservation, BobCommitObservationBoundary} from './consoleBobCommit.js'
export {
  REVEALING_CLAIM_INPUT_SCHEMA,
  REVEALING_CLAIM_REFERENCE_SCHEMA,
  createLocalRevealingClaimBoundary,
  submitRevealingClaim,
} from './consoleReveal.js'
export type {RevealingClaimPreview, RevealingClaimBoundary} from './consoleReveal.js'
export {
  REVEAL_OBSERVATION_SCHEMA,
  FINAL_CLAIM_JOURNAL_SCHEMA,
  createLocalRevealObservationBoundary,
  createLocalFinalClaimBoundary,
  observeReveal,
  submitFinalClaim,
} from './consoleFinalClaim.js'
export type {RevealLifecycle, RevealObservation, RevealObservationBoundary, FinalClaimPreview, FinalClaimBoundary} from './consoleFinalClaim.js'
export {CONSOLE_STATUS_SCHEMA, createLocalConsoleStatusBoundary, getConsoleStatus} from './consoleStatus.js'
export type {ConsoleBalance, ConsoleLegState, ConsoleLegStatus, ConsoleStatusBoundary, ConsoleStatusReport} from './consoleStatus.js'
export {RECLAIM_JOURNAL_SCHEMA, RECOVERY_INPUT_SCHEMA, submitReclaim, enterConsoleRecovery} from './consoleReclaim.js'
export type {ReclaimTransactionLifecycle, ReclaimTransactionStatus, ReclaimPreview, ReclaimBoundary} from './consoleReclaim.js'
export {
  CLIENT_STATE_SCHEMA,
  persistProtocolTerms,
  restoreProtocolTerms,
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
export {
  SECRET_STATE_SCHEMA,
  validatePartyWorkflowState,
  savePartyWorkflowState,
  restorePartyWorkflowState,
} from './clientPersistence.js'
export {prepareTradeCommand, applyPartyCommand, cliWorkflowCommands} from './cliCommands.js'
export type {
  PrepareTradeCommandArgs,
  PreparedPartyStates,
  AppliedPartyCommand,
} from './cliCommands.js'
export {
  trustedClientStatus,
  trustedClientCliOutput,
  formatTrustedClientStatus,
  assertRedactedOutput,
} from './cliOutput.js'
export type {TrustedClientStatusResult} from './cliOutput.js'
export {CONSOLE_SUMMARY_SCHEMA, summarizeConsoleOutput} from './consoleSummary.js'
export type {
  SecretStateMode,
  AliceSecretState,
  BobSecretState,
  PartySecretState,
  RestoredPartyWorkflowState,
} from './clientPersistence.js'

export {assetSupportRegistryAbi} from './generated/assetSupportRegistryAbi.js'
export {directAuthorizationAbi} from './generated/directAuthorizationAbi.js'
export {crossChainWrapperAbi} from './generated/crossChainWrapperAbi.js'
export {sameChainWrapperAbi} from './generated/sameChainWrapperAbi.js'
export {swapHTLCAbi} from './generated/swapHTLCAbi.js'
export {quipWalletAbi} from './generated/quipWalletAbi.js'
