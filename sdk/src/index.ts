/**
 * @quip.network/quip-swap-sdk — typed, non-custodial access to the Quip
 * Swap `Omnibus` contract (hashlocked same-chain and cross-chain swaps).
 *
 * Layering (import only what you need):
 * - Pure protocol helpers: {@link AssetType}, {@link Asset}, {@link Terms},
 *   asset builders, terms/pairing/window validators, hashing, secrets.
 * - Chain access: {@link createOmnibusClient} (reads + preflighted writes),
 *   approval planning, receipt and event helpers.
 * - Workflows: same-chain plan/status helpers and cross-chain schedule
 *   validation/coordination helpers.
 *
 * Internal test utilities (Anvil runners, artifact deployers) are NOT
 * exported — they are test infrastructure, not SDK surface.
 */

// types
export {AssetType, LockState} from './types.js'
export type {Asset, Terms, Hex32, SecretLockPair} from './types.js'

// errors
export {QuipSwapError, extractContractErrorName, wrapContractError} from './errors.js'
export type {QuipSwapErrorCode, QuipSwapErrorDetails} from './errors.js'

// asset builders + validation
export {nativeAsset, erc20Asset, erc721Asset, erc1155Asset, validateAsset, totalNative} from './assets.js'

// terms + pairing
export {createTerms, validateTerms, validateTermPairing, proposedBy} from './terms.js'
export type {CreateTermsArgs} from './terms.js'

// windows
export {
  MAX_UINT256,
  enforceWithin,
  isWithinWindow,
  proposerCommitWindow,
  takerCommitWindow,
  proposerClaimWindow,
  takerClaimWindow,
  reclaimWindow,
  validateCommitWindow,
  validateClaimWindow,
  validateReclaimWindow,
} from './windows.js'
export type {TimeWindow} from './windows.js'

// hashing
export {
  digestTerms,
  digestTermsCanonically,
  generateLock,
  assertHex32,
  assetArrayAbiParameter,
  termsAbiParameter,
} from './hashing.js'

// secrets
export {generateSecret, secretToPair} from './secrets.js'

// commit authorization (signer blobs + digest; the SDK never signs)
export {
  COMMIT_DIGEST_TAG,
  buildKeyedSigner,
  assertSignerBlob,
  computeDomainSeparator,
  computeCommitDigest,
} from './commitAuth.js'
export type {CommitAuth, ComputeCommitDigestArgs} from './commitAuth.js'

// deployments
export {knownDeployments, resolveDeployment, OMNIBUS_CREATE3_ADDRESS} from './deployments.js'
export type {OmnibusDeployment} from './deployments.js'

// gas estimation + transaction options
export {
  DEFAULT_GAS_MULTIPLIER,
  MIN_GAS_MULTIPLIER,
  MAX_GAS_MULTIPLIER,
  resolveGasMultiplier,
  applyGasMultiplier,
  buildFeeOverrides,
  preflightBalanceCheck,
  prepareTx,
} from './gas.js'
export type {TxOptions, FeeOverrides, PrepareTxArgs, PrepareTxContractParams, PreparedTx} from './gas.js'

// client
export {createOmnibusClient} from './client.js'
export type {
  CreateOmnibusClientArgs,
  OmnibusClient,
  OmnibusAdmin,
  CommitArgs,
  ClaimArgs,
  ReclaimArgs,
} from './client.js'

// approvals
export {planApprovals, submitApproval} from './approvals.js'
export type {
  ApprovalItem,
  ApprovalPlan,
  Erc20ApprovalItem,
  Erc721ApprovalItem,
  Erc1155ApprovalItem,
  Erc20ApprovalMode,
  PlanApprovalsArgs,
  SubmitApprovalArgs,
} from './approvals.js'

// receipts
export {waitForOmnibusReceipt} from './receipts.js'
export type {OmnibusReceipt, WaitOptions} from './receipts.js'

// events
export {
  decodeCommitmentEvents,
  decodeClaimEvents,
  decodeReclaimedEvents,
  extractRevealedSecret,
  extractSecretFromClaims,
  getCommitmentEvents,
  getClaimEvents,
  getReclaimedEvents,
  watchClaimEvents,
} from './events.js'
export type {CommitmentEvent, ClaimEvent, ReclaimedEvent, EventQueryArgs} from './events.js'

// buffers (schedule gap-size defaults + shared check)
export {
  DEFAULT_BUFFERS,
  DEFAULT_CROSS_CHAIN_BUFFER_SECONDS,
  DEFAULT_SAME_CHAIN_BUFFER_SECONDS,
  checkScheduleBuffers,
} from './buffers.js'

// workflows
export {planSameChainSwap, getSameChainSwapStatus} from './workflows/sameChain.js'
export type {SameChainSwapPlan, SameChainSwapStatus, SameChainSwapStatusReport} from './workflows/sameChain.js'
export {validateCrossChainSchedule, verifyRemoteCommitment, deriveSharedLock} from './workflows/crossChain.js'
export type {
  ValidateCrossChainScheduleArgs,
  CrossChainSchedule,
  RemoteCommitmentStatus,
} from './workflows/crossChain.js'

// generated
export {omnibusAbi} from './generated/omnibusAbi.js'


// v1.1 protocol primitives
export {
  AuthorizationMode, DelegationPolicy, WrapperMode, SideTag, ActionTag, RegistryActionTag, KeyRole,
  ExpectedSourceState,
  wrapperMode, gateTerms, gateContextId, deriveCommitLock, tradeId, settlementLock, timingPolicyId,
  assetHash, commitPayloadHash, encodeAuthorizationNonceKey, encodeRegistryNonceKey, validateProtocolTerms,
} from "./protocol.js"
export type {SideTerms, ProtocolTerms, TimingPolicy, CommitPayloadArgs} from "./protocol.js"
