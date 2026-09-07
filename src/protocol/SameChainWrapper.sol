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

  // Ordered Alice and Bob side terms.
  ProtocolTerms,

  // Joint commit, pending settlement, and terminal states.
  SameChainState,

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
// Import joint lifecycle storage and per-side settlement progress.
import {SameChainStateMachine} from './StateMachines.sol';
// Import standard ERC-1155 receiver callbacks for safe custody transfers.
import {ERC1155Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/utils/ERC1155Holder.sol';
// Import standard ERC-721 receiver callback for safe custody transfers.
import {ERC721Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/utils/ERC721Holder.sol';
// Import protection against nested guarded custody entry points.
import {ReentrancyGuard} from '@openzeppelin-contracts-5.6.0-rc.1/utils/ReentrancyGuard.sol';

/// @title SameChainWrapper
/// @notice Escrows two local legs and settles a selected outcome through resumable side execution.
/// @dev Commits must arrive from the authorization boundary named by the terms. Claims and
///      reclaims are permissionless because terms fix every payout recipient. Wallet-mode
///      provenance is not factory-checked here; the signed principal address is the trust boundary.
contract SameChainWrapper is

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
  // Attach joint lifecycle storage and per-side settlement progress to the corresponding storage or terms type.
  using SameChainStateMachine for SameChainStateMachine.Layout;
  // Attach claim, reclaim, and selected-batch settlement predicates to the corresponding storage or terms type.
  using Settlement for SameChainStateMachine.Layout;

  // A required deployment dependency or timing budget is missing or invalid.
  error ZeroConfiguration();
  // These terms select a different wrapper mode.
  error InvalidWrapperMode();
  // The selected terms do not name the executing chain.
  error InvalidLocalChain();
  // The exclusive commitment deadline has been reached.
  error CommitWindowClosed();
  // A custody clone is already indexed for this trade, lock, and side.
  error HTLCAlreadyExists();
  // This wrapper requires outcome selection followed by resumable execution.
  error AtomicSettlementDisabled();

  // Expose the exact admitted trade, lock, side, and funding principal.
  event Committed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address principal);
  // Expose the dedicated custody address for the committed trade side.
  event HTLCCreated(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address htlc);
  // Report irreversible joint claim selection before any payout execution.
  event ClaimSelected(bytes32 indexed tradeId, bytes32 indexed lock);
  // Report irreversible joint reclaim selection and its required side bitmap.
  event ReclaimSelected(bytes32 indexed tradeId, bytes32 indexed lock, uint8 expectedSides);
  // Report progress for one bounded custody-side release.
  event SettlementBatchExecuted(
    // Identify the exact side and the first unreleased asset, plus whether that side is complete.
    bytes32 indexed tradeId,
    bytes32 indexed lock,
    SideTag indexed side,
    uint256 nextAssetIndex,
    bool complete
  );
  // Report that one selected side has finished its entire payout.
  event SideReleased(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side);
  // Report completion of the applicable claim payout or joint claim outcome.
  event Claimed(bytes32 indexed tradeId, bytes32 indexed lock);
  // Report completion of the applicable reclaim payout or joint reclaim outcome.
  event Reclaimed(bytes32 indexed tradeId, bytes32 indexed lock);

  /// @notice Gateway trusted to authenticate RegisteredDirect commit signatures.
  address public immutable DIRECT_AUTHORIZATION;
  /// @notice Admission allowlist consulted only when new assets enter custody.
  IAssetSupportRegistry public immutable ASSET_SUPPORT;
  /// @notice Non-upgradeable implementation cloned once for every committed side.
  address public immutable HTLC_IMPLEMENTATION;

  // Store the joint lifecycle and selected-outcome progress for each local trade.
  SameChainStateMachine.Layout private states;
  // Retain the unused aggregate reserve layout solely for the compatibility view.
  AssetCustody.Layout private custody;
  // Index custody clone addresses by the complete hashed record identity.
  mapping(bytes32 recordKey => address htlc) private htlcs;

  /// @notice Configures the immutable direct authorization gateway and asset allowlist.
  constructor(
    // Direct-user gateway pinned by this deployment.
    address directAuthorization,
    // Admission registry for compatible token contracts.
    IAssetSupportRegistry assetSupport,
    // Deployed implementation to clone for dedicated custody.
    address htlcImplementation,
    // Initial administrator of wrapper commitment fees.
    address initialOwner
    // Initialize inherited fee ownership while pinning this wrapper's dependencies.
  ) CommitmentFees(initialOwner) {
    // Require an authorization gateway, asset registry, and deployed custody implementation.
    if (directAuthorization == address(0) || address(assetSupport) == address(0) || htlcImplementation.code.length == 0)
    {
      // A required deployment dependency or timing budget is missing or invalid.
      revert ZeroConfiguration();
    }

    // Pin the gateway that may supply direct-user authorization evidence.
    DIRECT_AUTHORIZATION = directAuthorization;
    // Pin the asset registry consulted when new custody is admitted.
    ASSET_SUPPORT = assetSupport;
    // Pin the implementation used by every subsequently deployed custody clone.
    HTLC_IMPLEMENTATION = htlcImplementation;
  }

  /// @notice Validates authorization and funding, then records the next ordered local commit.
  /// @dev The party must commit first. Same-chain commits carry no Bob-commit progression secret.
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
    // Copy calldata once, then validate the complete same-chain term set.
    ProtocolTerms memory validatedTerms = terms;
    // Validate the complete terms before recording any commitment.
    _validate(validatedTerms);

    // Select the funded leg; both terms must name this deployment chain.
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

    // Same-chain execution must not carry the cross-chain progression secret.
    ProgressionGate.validate(validatedTerms, bobCommitSecret);

    // Treat the commitment deadline as an exclusive upper bound.
    if (block.timestamp >= side.commitmentDeadline) revert CommitWindowClosed();

    // The wrapper retains the live fee and forwards only terms-declared escrow.
    _requireCommitValue(side.nativeAmount());

    // Enforce party-first ordering through the joint state machine before external calls.
    if (party) states.commitParty(trade, lock);
    // Accept Bob only from the joint PartyCommitted state.
    else states.commitCounterparty(trade, lock);

    // Translate the boolean selector into the canonical side tag.
    SideTag tag = ProtocolHashing.sideTag(party);
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
    emit Committed(trade, lock, ProtocolHashing.sideTag(party), side.principal);
    // Publish the custody clone address indexed for this committed side.
    emit HTLCCreated(trade, lock, tag, htlc);
  }

  /// @notice Permissionlessly and irreversibly selects claim without executing a payout.
  /// @dev Settlement does not consult either side's commit-only delegation policy.
  function selectClaim(ProtocolTerms calldata terms, bytes32 lock, bytes32 secret) external {
    // Validate the secret and claim window, then select the joint claim outcome.
    bytes32 trade = states.selectSameChainClaim(terms, lock, secret, block.timestamp);

    // Report the irreversible claim selection before payout execution.
    emit ClaimSelected(trade, lock);
  }

  /// @notice Permissionlessly and irreversibly selects the applicable reclaim without a payout.
  /// @dev Settlement does not consult either side's commit-only delegation policy.
  function selectReclaim(ProtocolTerms calldata terms, bytes32 lock) external {
    // Hash all ordered terms to recover the identity used by the committed record.
    bytes32 trade = ProtocolHashing.tradeId(terms);
    // Read the joint lifecycle to distinguish sole-party recovery from two-sided recovery.
    SameChainState current = states.state(trade, lock);

    // Choose sole-party recovery only when Bob never committed.
    if (current == SameChainState.PartyCommitted) {
      // Select reclaim after the party release time and require a sole-party commitment.
      trade = states.selectSameChainPartyReclaim(terms, lock, block.timestamp);
      // Delegate other source states to two-sided recovery, which rejects inadmissible states.
    } else {
      // Require both committed sides and both release times before selecting joint reclaim.
      trade = states.selectSameChainBothReclaim(terms, lock, block.timestamp);
    }

    // Read which funded sides the selected reclaim must finish.
    (uint8 expectedSides,) = states.settlementProgress(trade, lock);

    // Report the irreversible reclaim selection and its required side bitmap.
    emit ReclaimSelected(trade, lock, expectedSides);
  }

  /// @notice Releases one required HTLC side for an already selected outcome.
  /// @dev Any caller may execute. The selected outcome and terms fix the recipient, while
  ///      `maxAssets` bounds this call's progress through the selected HTLC.
  function executeSettlement(
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms calldata terms,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // True selects Alice's party side; false selects Bob's counterparty side.
    bool party,
    // Maximum number of assets this call may release.
    uint256 maxAssets
    // Guard external settlement execution against nested guarded calls.
  ) external nonReentrant {
    // Hash all ordered terms to recover the identity used by the committed record.
    bytes32 trade = ProtocolHashing.tradeId(terms);
    // Translate the boolean selector into the canonical side tag.
    SideTag side = ProtocolHashing.sideTag(party);

    // Reserve memory for the selected batch outcome and progress.
    Settlement.SameChainBatchResult memory result =
    // Execute the bounded batch on the custody clone indexed for this exact side.
    states.executeSelectedSameChainHTLC(_htlc(trade, lock, side), terms, party, lock, maxAssets);

    // Report the side cursor and whether this batch finished the side.
    emit SettlementBatchExecuted(result.trade, lock, side, result.nextAssetIndex, result.sideComplete);
    // Report a side release only when this batch finishes the entire signed bundle.
    if (result.sideComplete) emit SideReleased(result.trade, lock, side);

    // Emit a terminal event only after every required side has completed.
    if (result.terminal) {
      // Report completion of the previously selected claim outcome.
      if (result.outcome == SameChainState.ClaimPending) emit Claimed(result.trade, lock);
      // Otherwise report completion of the previously selected reclaim outcome.
      else emit Reclaimed(result.trade, lock);
    }
  }

  /// @notice Disabled legacy atomic claim entry point.
  function claim(ProtocolTerms calldata, bytes32, bytes32) external pure {
    // This wrapper requires outcome selection followed by resumable execution.
    revert AtomicSettlementDisabled();
  }

  /// @notice Disabled legacy atomic party-reclaim entry point.
  function reclaimParty(ProtocolTerms calldata, bytes32) external pure {
    // This wrapper requires outcome selection followed by resumable execution.
    revert AtomicSettlementDisabled();
  }

  /// @notice Disabled legacy atomic dual-reclaim entry point.
  function reclaimBoth(ProtocolTerms calldata, bytes32) external pure {
    // This wrapper requires outcome selection followed by resumable execution.
    revert AtomicSettlementDisabled();
  }

  /// @notice Returns the joint state for these exact terms and settlement lock.
  function state(ProtocolTerms calldata terms, bytes32 lock) external view returns (SameChainState) {
    // Return the joint state keyed by the complete terms and settlement lock.
    return states.state(ProtocolHashing.tradeId(terms), lock);
  }

  /// @notice Returns the required and completed side bitmaps for a selected settlement.
  function settlementProgress(
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms calldata terms,
    // Trade-bound settlement hash lock.
    bytes32 lock
    // Expose required and completed side masks without modifying storage.
  ) external view returns (uint8 expectedSides, uint8 completedSides) {
    // Return required and completed side bitmaps for this exact trade.
    return states.settlementProgress(ProtocolHashing.tradeId(terms), lock);
  }

  /// @notice Returns the deployed custody contract for one exact side, or zero before commit.
  function htlcOf(ProtocolTerms calldata terms, bool party, bytes32 lock) external view returns (address) {
    // Hash all ordered terms to recover the identity used by the committed record.
    bytes32 trade = ProtocolHashing.tradeId(terms);

    // Return the indexed custody clone, or zero if the side has not committed.
    return htlcs[HTLCDeployer.recordKey(trade, lock, ProtocolHashing.sideTag(party))];
  }

  /// @notice Predicts the deterministic custody address for one exact side.
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

  // Look up the dedicated custody clone for the exact trade, lock, and side.
  function _htlc(bytes32 trade, bytes32 lock, SideTag tag) private view returns (address) {
    // Return the indexed custody clone, or zero if the side has not committed.
    return htlcs[HTLCDeployer.recordKey(trade, lock, tag)];
  }

  // Validate wrapper mode and structural terms at commit admission.
  function _validate(ProtocolTerms memory terms) private pure {
    // These terms select a different wrapper mode.
    if (ProtocolHashing.mode(terms) != WrapperMode.SameChain) revert InvalidWrapperMode();

    // Validate the complete terms before recording any commitment.
    ProtocolHashing.validateTerms(terms);
  }
}
