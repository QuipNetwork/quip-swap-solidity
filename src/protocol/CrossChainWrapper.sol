// SPDX-License-Identifier: UNLICENSE
// Pin the compiler version used for these encodings and contract semantics.
pragma solidity 0.8.33;

// Import compatibility accounting and release helpers for pooled custody; Native-value calculation and direct
// principal-to-HTLC token funding.
import {AssetCustody, HTLCFunding} from '../assets/AssetHandling.sol';
// Import admission checks against the configured asset registry.
import {AssetSupport} from '../assets/AssetHandling.sol';
// Import read interface for compatible-asset admission.
import {IAssetSupportRegistry} from '../interfaces/IAssetSupportRegistry.sol';
// Import atomic authorized-commit callback interface.
import {ICommitAuthorizationReceiver} from '../interfaces/ICommitAuthorizationReceiver.sol';
// Import custody initialization, funding, binding, and release interface.
import {ISwapHTLC} from '../interfaces/ISwapHTLC.sol';
// Import verification of evidence supplied by the authentication boundary.
import {CommitAuthorization} from './CommitValidation.sol';
// Import verification of the cross-chain Bob-commit preimage.
import {ProgressionGate} from './CommitValidation.sol';
// Import shared live-fee accounting and two-step ownership.
import {CommitmentFees} from './CommitmentFees.sol';
// Import deterministic custody clone deployment and lookup helpers.
import {HTLCDeployer} from './HTLCDeployer.sol';
// Import canonical term validation and domain-separated identifiers.
import {ProtocolHashing} from './ProtocolHashing.sol';
// Import the canonical types used by this protocol component.
import {

  // Unused, committed, and terminal local-leg states.
  CrossChainLegState,

  // Ordered Alice and Bob side terms.
  ProtocolTerms,

  // Canonical party and counterparty side tags.
  SideTag,

  // One side's signed assets, identities, destinations, and deadlines.
  SideTerms,

  // Evidence passed from a wallet or direct gateway to the wrapper.
  VerifiedCommitAuthorization,

  // Cross-chain or same-chain execution discriminator.
  WrapperMode
} from './ProtocolTypes.sol';
// Import canonical token identity and quantity representation.
import {Asset} from './ProtocolTypes.sol';
// Import claim, reclaim, and selected-batch settlement predicates.
import {Settlement} from './Settlement.sol';
// Import independent lifecycle storage and transitions for each local leg.
import {CrossChainStateMachine} from './StateMachines.sol';
// Import standard ERC-1155 receiver callbacks for safe custody transfers.
import {ERC1155Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/utils/ERC1155Holder.sol';
// Import standard ERC-721 receiver callback for safe custody transfers.
import {ERC721Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/utils/ERC721Holder.sol';
// Import protection against nested guarded custody entry points.
import {ReentrancyGuard} from '@openzeppelin-contracts-5.6.0-rc.1/utils/ReentrancyGuard.sol';

/// @title CrossChainWrapper
/// @notice Escrows and settles one local leg of a v1.1 cross-chain swap.
/// @dev Commits must arrive atomically from the authorization boundary named by the terms.
///      Claims and reclaims are permissionless because terms fix their recipients. Wallet-mode
///      provenance is not factory-checked here; the signed principal address is the trust boundary.
contract CrossChainWrapper is

  // Atomic authorized-commit callback interface.
  ICommitAuthorizationReceiver,
  // Shared live-fee accounting and two-step ownership.
  CommitmentFees,
  // Standard ERC-721 receiver callback for safe custody transfers.
  ERC721Holder,
  // Standard ERC-1155 receiver callbacks for safe custody transfers.
  ERC1155Holder,
  // Protection against nested guarded custody entry points.
  ReentrancyGuard
{
  // Attach compatibility accounting and release helpers for pooled custody to the corresponding storage or terms type.
  using AssetCustody for AssetCustody.Layout;
  // Attach native-value calculation and direct principal-to-htlc token funding to the corresponding storage or terms
  // type.
  using HTLCFunding for SideTerms;
  // Attach admission checks against the configured asset registry to the corresponding storage or terms type.
  using AssetSupport for SideTerms;
  // Attach independent lifecycle storage and transitions for each local leg to the corresponding storage or terms type.
  using CrossChainStateMachine for CrossChainStateMachine.Layout;
  // Attach claim, reclaim, and selected-batch settlement predicates to the corresponding storage or terms type.
  using Settlement for CrossChainStateMachine.Layout;

  // A required deployment dependency or timing budget is missing or invalid.
  error ZeroConfiguration();
  // These terms select a different wrapper mode.
  error InvalidWrapperMode();
  // The selected terms do not name the executing chain.
  error InvalidLocalChain();
  // The reveal deadline leaves less than the configured final-claim budget.
  error InsufficientFinalClaimWindow();
  // The exclusive commitment deadline has been reached.
  error CommitWindowClosed();
  // A custody clone is already indexed for this trade, lock, and side.
  error HTLCAlreadyExists();

  // Expose the exact admitted trade, lock, side, and funding principal.
  event Committed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address principal);
  // Publish Alice's progression preimage so Bob can observe the first commit.
  event BobCommitSecretPublished(bytes32 indexed tradeId, bytes32 bobCommitSecret);
  // Expose the dedicated custody address for the committed trade side.
  event HTLCCreated(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address htlc);
  // Report completion of the applicable claim payout or joint claim outcome.
  event Claimed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side);
  // Report completion of the applicable reclaim payout or joint reclaim outcome.
  event Reclaimed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side);

  /// @notice Gateway trusted to authenticate RegisteredDirect commit signatures.
  address public immutable DIRECT_AUTHORIZATION;
  /// @notice Admission allowlist consulted only when new assets enter custody.
  IAssetSupportRegistry public immutable ASSET_SUPPORT;
  /// @notice Non-upgradeable implementation cloned once for every committed local leg.
  address public immutable HTLC_IMPLEMENTATION;
  /// @notice Minimum seconds reserved from counterparty reveal deadline to party final-claim deadline.
  /// @dev Deployment review must cover finality, observation, inclusion and timestamp skew for every supported route.
  uint256 public immutable FINAL_CLAIM_DELAY;

  // Store independent lifecycle records for the locally committed legs.
  CrossChainStateMachine.Layout private states;
  // Retain the unused aggregate reserve layout solely for the compatibility view.
  AssetCustody.Layout private custody;
  // Index custody clone addresses by the complete hashed record identity.
  mapping(bytes32 recordKey => address htlc) private htlcs;

  /// @notice Configures the immutable dependencies and reviewed final-claim delivery budget.
  constructor(
    // Direct-user gateway pinned by this deployment.
    address directAuthorization,
    // Admission registry for compatible token contracts.
    IAssetSupportRegistry assetSupport,
    // Deployed implementation to clone for dedicated custody.
    address htlcImplementation,
    // Initial administrator of wrapper commitment fees.
    address initialOwner,
    // Reviewed positive minimum seconds reserved for final-claim delivery.
    uint256 finalClaimDelay
    // Initialize inherited fee ownership while pinning this wrapper's dependencies.
  ) CommitmentFees(initialOwner) {
    // Validate deployment dependencies and the mandatory final-claim budget together.
    if (
      // Require an authorization gateway, asset registry, and deployed custody implementation.
      directAuthorization == address(0) || address(assetSupport) == address(0) || htlcImplementation.code.length == 0
        // Reject a zero delivery budget rather than silently disabling the final-claim margin.
        || finalClaimDelay == 0
    ) {
      // A required deployment dependency or timing budget is missing or invalid.
      revert ZeroConfiguration();
    }

    // Pin the gateway that may supply direct-user authorization evidence.
    DIRECT_AUTHORIZATION = directAuthorization;
    // Pin the asset registry consulted when new custody is admitted.
    ASSET_SUPPORT = assetSupport;
    // Pin the implementation used by every subsequently deployed custody clone.
    HTLC_IMPLEMENTATION = htlcImplementation;
    // Pin the reviewed minimum delivery budget for all admitted cross-chain schedules.
    FINAL_CLAIM_DELAY = finalClaimDelay;
  }

  /// @notice Validates authorization evidence, the Bob-commit gate, and funding, then escrows one leg.
  /// @dev Both cross-chain commits provide the same preimage; the party-side commit publishes it
  ///      through BobCommitSecretPublished so the counterparty can progress from on-chain data.
  function receiveAuthorizedCommit(
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms calldata terms,
    // True selects Alice's party side; false selects Bob's counterparty side.
    bool party,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Progression preimage for cross-chain commits; zero for same-chain commits.
    bytes32 bobCommitSecret,
    // Caller, submitter, and payload evidence produced by the authorization boundary.
    VerifiedCommitAuthorization calldata evidence,
    // The callback reserves opaque data for interface compatibility; this wrapper does not consume it.
    bytes calldata
    // Accept native escrow and fees while rejecting reentry into guarded wrapper operations.
  ) external payable nonReentrant {
    // Copy calldata once, then validate the complete cross-chain term set.
    ProtocolTerms memory validatedTerms = terms;
    // Validate the complete terms before recording any commitment.
    _validate(validatedTerms);

    // Alice reveals on the counterparty leg; Bob must still be able to claim the party leg.
    // Subtraction after ordering avoids overflow even for adversarial uint256 deadlines.
    if (
      // Require the revealing leg's deadline to precede the final-claim deadline.
      validatedTerms.counterpartySide.claimDeadline >= validatedTerms.partySide.claimDeadline
        // After checking order, subtract safely and require the full configured delivery budget.
        || validatedTerms.partySide.claimDeadline - validatedTerms.counterpartySide.claimDeadline < FINAL_CLAIM_DELAY
      // The reveal deadline leaves less than the configured final-claim budget.
    ) revert InsufficientFinalClaimWindow();

    // Select the funded leg and require this deployment to be its named chain.
    SideTerms memory side = party ? validatedTerms.partySide : validatedTerms.counterpartySide;
    // The selected terms do not name the executing chain.
    if (side.chainId != block.chainid) revert InvalidLocalChain();
    // Reject local destinations that would trap a payout inside the executing wrapper.
    ProtocolHashing.validateLocalPayouts(validatedTerms, party, address(this));

    // Reject token contracts that have not passed the custody compatibility policy.
    side.requireSupported(ASSET_SUPPORT);

    // Bind gateway evidence to the exact trade, wrapper, leg, state, and fresh action nonce.
    bytes32 trade = CommitAuthorization.validate(
      // Pass the exact callback context and local timestamp into evidence validation.
      validatedTerms,
      party,
      DIRECT_AUTHORIZATION,
      address(this),
      lock,
      msg.sender,
      evidence,
      block.timestamp
    );

    // Prove knowledge of Bob commit secret before either cross-chain leg can be funded.
    ProgressionGate.validate(validatedTerms, bobCommitSecret);

    // Treat the commitment deadline as an exclusive upper bound.
    if (block.timestamp >= side.commitmentDeadline) revert CommitWindowClosed();

    // The wrapper retains the live fee and forwards only terms-declared escrow.
    _requireCommitValue(side.nativeAmount());

    // Advance state before interacting with the clone or any asset contract.
    SideTag tag = ProtocolHashing.sideTag(party);
    // Record the local committed state before clone initialization and token callbacks.
    states.commit(trade, lock, tag);
    // Derive the custody lookup key for this trade, lock, and side.
    bytes32 htlcKey = HTLCDeployer.recordKey(trade, lock, tag);
    // A custody clone is already indexed for this trade, lock, and side.
    if (htlcs[htlcKey] != address(0)) revert HTLCAlreadyExists();

    // Deploy and initialize one deterministic custody clone, forwarding native value directly.
    address htlc = HTLCDeployer.deploy(HTLC_IMPLEMENTATION, trade, lock, tag);
    // Bind clone storage to this side and forward only its signed native escrow.
    ISwapHTLC(htlc).initialize{value: side.nativeAmount()}(trade, lock, tag, side);

    // The wrapper remains the allowance spender but tokens move principal -> HTLC without pooling.
    side.transferNonNative(htlc);
    // Require the clone to observe its full signed asset bundle before accepting custody.
    ISwapHTLC(htlc).confirmFunding(side);
    // Publish the funded clone address in the wrapper custody index.
    htlcs[htlcKey] = htlc;

    // Accrue only after every custody operation succeeds, using the validated snapshot.
    _accrueCommitmentFee(msg.value - side.nativeAmount());

    // Report the exact admitted trade, settlement lock, side, and principal.
    emit Committed(trade, lock, tag, side.principal);
    // Publish the custody clone address indexed for this committed side.
    emit HTLCCreated(trade, lock, tag, htlc);
    // Alice party commit is the on-chain publication point for Bob commit secret.
    if (party) emit BobCommitSecretPublished(trade, bobCommitSecret);
  }

  /// @notice Permissionlessly claims the selected local leg to its fixed recipient.
  function claim(ProtocolTerms calldata terms, bool party, bytes32 lock, bytes32 secret) external nonReentrant {
    // Hash all ordered terms to recover the identity used by the committed record.
    bytes32 trade = ProtocolHashing.tradeId(terms);
    // Translate the boolean selector into the canonical side tag.
    SideTag tag = ProtocolHashing.sideTag(party);

    // Settlement validates the preimage and window, advances state, then releases this leg's HTLC.
    trade = states.claimCrossChainHTLC(
      // Use the indexed clone and supplied preimage under the current local claim timestamp.
      htlcs[HTLCDeployer.recordKey(trade, lock, tag)],
      terms,
      party,
      lock,
      secret,
      block.timestamp
    );

    // Report the completed claim for this trade and applicable side.
    emit Claimed(trade, lock, ProtocolHashing.sideTag(party));
  }

  /// @notice Permissionlessly reclaims the selected local leg to its fixed reclaim recipient.
  function reclaim(ProtocolTerms calldata terms, bool party, bytes32 lock) external nonReentrant {
    // Hash all ordered terms to recover the identity used by the committed record.
    bytes32 trade = ProtocolHashing.tradeId(terms);
    // Translate the boolean selector into the canonical side tag.
    SideTag tag = ProtocolHashing.sideTag(party);

    // Reclaim validates the release time, advances state, then returns this leg's HTLC.
    trade = states.reclaimCrossChainHTLC(
      // Use the indexed clone and current local timestamp for the reclaim release check.
      htlcs[HTLCDeployer.recordKey(trade, lock, tag)],
      terms,
      party,
      lock,
      block.timestamp
    );

    // Report the completed reclaim for this trade and applicable side.
    emit Reclaimed(trade, lock, ProtocolHashing.sideTag(party));
  }

  /// @notice Returns the state of the selected leg for these exact terms and lock.
  function state(ProtocolTerms calldata terms, bool party, bytes32 lock) external view returns (CrossChainLegState) {
    // Return the selected leg state keyed by the complete terms and settlement lock.
    return states.state(ProtocolHashing.tradeId(terms), lock, ProtocolHashing.sideTag(party));
  }

  /// @notice Returns the deployed custody contract for one exact local leg, or zero before commit.
  function htlcOf(ProtocolTerms calldata terms, bool party, bytes32 lock) external view returns (address) {
    // Hash all ordered terms to recover the identity used by the committed record.
    bytes32 trade = ProtocolHashing.tradeId(terms);

    // Return the indexed custody clone, or zero if the side has not committed.
    return htlcs[HTLCDeployer.recordKey(trade, lock, ProtocolHashing.sideTag(party))];
  }

  /// @notice Predicts the deterministic custody address for one exact local leg.
  function predictHTLC(ProtocolTerms calldata terms, bool party, bytes32 lock) external view returns (address) {
    // Compute the deterministic custody address without deploying a clone.
    return HTLCDeployer.predict(
      // Supply the pinned implementation, deploying wrapper, and full trade-side identity.
      HTLC_IMPLEMENTATION,
      address(this),
      ProtocolHashing.tradeId(terms),
      lock,
      ProtocolHashing.sideTag(party)
    );
  }

  /// @notice Compatibility view that always returns zero in this wrapper.
  /// @dev Commits fund dedicated HTLCs without populating the legacy aggregate reserve ledger.
  ///      Use htlcOf and the returned HTLC's state and asset balances to inspect custody.
  function reserved(Asset calldata asset) external view returns (uint256) {
    // Read the compatibility reserve ledger, which dedicated-HTLC commits do not populate.
    return custody.reservedAmount(asset);
  }

  // Validate wrapper mode and structural terms at commit admission.
  function _validate(ProtocolTerms memory terms) private pure {
    // These terms select a different wrapper mode.
    if (ProtocolHashing.mode(terms) != WrapperMode.CrossChain) revert InvalidWrapperMode();

    // Validate the complete terms before recording any commitment.
    ProtocolHashing.validateTerms(terms);
  }
}
