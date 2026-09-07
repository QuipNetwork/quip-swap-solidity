// SPDX-License-Identifier: UNLICENSE
// Pin the compiler version used for these encodings and contract semantics.
pragma solidity 0.8.33;

// Import compatibility accounting and release helpers for pooled custody.
import {AssetCustody} from '../assets/AssetHandling.sol';
// Import custody initialization, funding, binding, and release interface.
import {ISwapHTLC} from '../interfaces/ISwapHTLC.sol';
// Import canonical term validation and domain-separated identifiers.
import {ProtocolHashing} from './ProtocolHashing.sol';
// Import ordered Alice and Bob side terms; Joint commit, pending settlement, and terminal states; Canonical party and
// counterparty side tags; One side's signed assets, identities, destinations, and deadlines; Cross-chain or same-chain
// execution discriminator.
import {ProtocolTerms, SameChainState, SideTag, SideTerms, WrapperMode} from './ProtocolTypes.sol';
// Import independent lifecycle storage and transitions for each local leg.
import {CrossChainStateMachine} from './StateMachines.sol';
// Import joint lifecycle storage and per-side settlement progress.
import {SameChainStateMachine} from './StateMachines.sol';

/// @title Settlement
/// @notice Applies claim and reclaim predicates, advances state, and releases reserved assets.
/// @dev Claim and reclaim are permissionless; terms fix the payout recipient. State is advanced
///      before external asset transfers, and wrapper entry points additionally use a reentrancy guard.
library Settlement {
  // Attach compatibility accounting and release helpers for pooled custody to the corresponding storage or terms type.
  using AssetCustody for AssetCustody.Layout;
  // Attach independent lifecycle storage and transitions for each local leg to the corresponding storage or terms type.
  using CrossChainStateMachine for CrossChainStateMachine.Layout;
  // Attach joint lifecycle storage and per-side settlement progress to the corresponding storage or terms type.
  using SameChainStateMachine for SameChainStateMachine.Layout;

  // These terms select a different settlement mode.
  error InvalidSettlementMode();
  // The selected terms do not name the executing chain.
  error InvalidLocalChain();
  // The settlement preimage does not open this trade's lock.
  error InvalidSettlementSecret();
  // The applicable exclusive claim deadline has been reached.
  error ClaimWindowClosed();
  // The applicable inclusive reclaim release has not been reached.
  error ReclaimWindowClosed();
  // A required custody instance is absent.
  error MissingHTLC();
  // The custody instance is not bound to this wrapper and exact side.
  error InvalidHTLCBinding();
  // A settlement batch must allow at least one asset.
  error InvalidBatchSize();

  // Return the selected outcome and progress from a bounded custody release.
  struct SameChainBatchResult {
    // Identifier of the exact complete trade terms.
    bytes32 trade;
    // Pending outcome selected before this batch executed.
    SameChainState outcome;
    // First asset not yet released from the signed bundle.
    uint256 nextAssetIndex;
    // Whether the selected side has released its entire asset bundle.
    bool sideComplete;
    // Whether every required side payout has completed.
    bool terminal;
  }

  /// @notice Selects the same-chain claim outcome without executing a payout.
  function selectSameChainClaim(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Preimage that must open the trade-bound settlement lock.
    bytes32 secret,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Require the mode served by this settlement entry point; committed lookup supplies structural validity.
    _validate(terms, WrapperMode.SameChain);
    // Require both sides to belong to the executing chain.
    _requireBothLocal(terms);

    // Hash all ordered terms to recover the identity used by the committed record.
    trade = ProtocolHashing.tradeId(terms);
    // Check that the supplied preimage opens the settlement lock for this exact trade.
    _requireSecret(trade, lock, secret);

    // Select the earlier of the two claim deadlines for joint outcome selection.
    uint256 deadline = terms.partySide.claimDeadline < terms.counterpartySide.claimDeadline
      // Use Alice's deadline when it is the earlier claim cutoff.
      ? terms.partySide.claimDeadline
      // Otherwise use Bob's deadline as the joint claim cutoff.
      : terms.counterpartySide.claimDeadline;
    // The applicable exclusive claim deadline has been reached.
    if (timestamp >= deadline) revert ClaimWindowClosed();

    // Select ClaimPending and require both committed sides.
    self.selectClaim(trade, lock);
  }

  /// @notice Selects one-sided same-chain reclaim without executing a payout.
  function selectSameChainPartyReclaim(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Require the mode served by this settlement entry point; committed lookup supplies structural validity.
    _validate(terms, WrapperMode.SameChain);
    // Require both sides to belong to the executing chain.
    _requireBothLocal(terms);

    // The applicable inclusive reclaim release has not been reached.
    if (timestamp < terms.partySide.reclaimRelease) revert ReclaimWindowClosed();

    // Hash all ordered terms to recover the identity used by the committed record.
    trade = ProtocolHashing.tradeId(terms);

    // Select ReclaimPending with only the party side required.
    self.selectReclaimParty(trade, lock);
  }

  /// @notice Selects two-sided same-chain reclaim without executing a payout.
  function selectSameChainBothReclaim(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Require the mode served by this settlement entry point; committed lookup supplies structural validity.
    _validate(terms, WrapperMode.SameChain);
    // Require both sides to belong to the executing chain.
    _requireBothLocal(terms);
    // Two-sided recovery opens only after both signed reclaim releases.
    if (timestamp < terms.partySide.reclaimRelease || timestamp < terms.counterpartySide.reclaimRelease) {
      // The applicable inclusive reclaim release has not been reached.
      revert ReclaimWindowClosed();
    }

    // Hash all ordered terms to recover the identity used by the committed record.
    trade = ProtocolHashing.tradeId(terms);

    // Select ReclaimPending with both committed sides required.
    self.selectReclaimBoth(trade, lock);
  }

  /// @notice Completes a selected same-chain claim after all required payouts finish.
  /// @dev Deliberately has no timestamp argument: the claim window applies only to selection.
  function completeSelectedSameChainClaim(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Identifier of the exact complete trade terms.
    bytes32 trade,
    // Trade-bound settlement hash lock.
    bytes32 lock
    // Apply this internal lifecycle transition to the caller-owned layout.
  ) internal {
    // Finalize Claimed only when all required side bits are complete.
    self.completeClaim(trade, lock);
  }

  /// @notice Completes a selected same-chain reclaim after all required payouts finish.
  /// @dev Deliberately has no timestamp argument: reclaim releases apply only to selection.
  function completeSelectedSameChainReclaim(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Identifier of the exact complete trade terms.
    bytes32 trade,
    // Trade-bound settlement hash lock.
    bytes32 lock
    // Apply this internal lifecycle transition to the caller-owned layout.
  ) internal {
    // Finalize Reclaimed only when all required side bits are complete.
    self.completeReclaim(trade, lock);
  }

  /// @notice Executes one selected same-chain HTLC side without rechecking selection timing.
  /// @dev Partial batches preserve the pending outcome and do not mark their side complete.
  function executeSelectedSameChainHTLC(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Dedicated custody clone indexed for the selected side.
    address htlc,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // True selects Alice's party side; false selects Bob's counterparty side.
    bool party,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Maximum number of assets this call may release.
    uint256 maxAssets
    // Return the selected outcome and persisted batch progress to the wrapper.
  ) internal returns (SameChainBatchResult memory result) {
    // Require the mode served by this settlement entry point; committed lookup supplies structural validity.
    _validate(terms, WrapperMode.SameChain);
    // Require both sides to belong to the executing chain.
    _requireBothLocal(terms);
    // A settlement batch must allow at least one asset.
    if (maxAssets == 0) revert InvalidBatchSize();

    // Hash all ordered terms to recover the identity used by the committed record.
    result.trade = ProtocolHashing.tradeId(terms);
    // Read the irreversible outcome selected in an earlier transaction.
    result.outcome = self.state(result.trade, lock);
    // Reject execution unless claim or reclaim was selected in the joint record.
    if (result.outcome != SameChainState.ClaimPending && result.outcome != SameChainState.ReclaimPending) {
      // No claim or reclaim outcome is pending execution.
      revert SameChainStateMachine.SettlementNotPending(result.outcome);
    }

    // Translate the boolean selector into the canonical side tag.
    SideTag tag = ProtocolHashing.sideTag(party);
    {
      // Read the exact signed terms for the selected escrow leg.
      SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
      // Choose the signed destination solely from the already selected outcome.
      address recipient = result.outcome == SameChainState.ClaimPending ? side.recipient : side.reclaimRecipient;
      // Capture the next asset cursor and whether this side has finished.
      (result.nextAssetIndex, result.sideComplete) =
      // Check side eligibility and clone binding before releasing this batch.
      _executeSelectedBatch(self, htlc, side, recipient, result.trade, lock, tag, maxAssets);
    }

    // Read aggregate progress after any newly completed side was recorded.
    (uint8 expectedSides, uint8 completedSides) = self.settlementProgress(result.trade, lock);
    // The trade is terminal only when every expected side bit is complete.
    result.terminal = completedSides == expectedSides;

    // Emit a terminal event only after every required side has completed.
    if (result.terminal) {
      // Complete the selected claim without imposing a second claim deadline.
      if (result.outcome == SameChainState.ClaimPending) completeSelectedSameChainClaim(self, result.trade, lock);
      // Complete the selected reclaim after all required releases.
      else completeSelectedSameChainReclaim(self, result.trade, lock);
    }
  }

  // Bind and release one required custody side while retaining progress across batches.
  function _executeSelectedBatch(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Dedicated custody clone indexed for the selected side.
    address htlc,
    // Ordered side whose assets or state this operation addresses.
    SideTerms memory side,
    // Fixed signed payout destination selected by the outcome.
    address recipient,
    // Identifier of the exact complete trade terms.
    bytes32 trade,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Ordered side whose assets or state this operation addresses.
    SideTag tag,
    // Maximum number of assets this call may release.
    uint256 maxAssets
    // Return the new asset cursor and whether this side has finished.
  ) private returns (uint256 nextIndex, bool sideComplete) {
    // Reject an unexpected or completed side before consulting its exact committed HTLC.
    self.requirePendingSide(trade, lock, tag);
    // Require controller, trade, lock, side, and side-terms hash to match custody.
    _requireHTLCBinding(htlc, trade, lock, tag, side);

    // Release at most maxAssets; failed transfers revert this batch, not earlier successful batches.
    (nextIndex, sideComplete) = ISwapHTLC(htlc).releaseBatch(side, recipient, maxAssets);

    // Partial batches leave the side incomplete so execution can resume.
    if (sideComplete) self.markSideComplete(trade, lock, tag);
  }

  /// @notice Claims one local cross-chain leg held by its dedicated HTLC.
  function claimCrossChainHTLC(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    CrossChainStateMachine.Layout storage self,
    // Dedicated custody clone indexed for the selected side.
    address htlc,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // True selects Alice's party side; false selects Bob's counterparty side.
    bool party,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Preimage that must open the trade-bound settlement lock.
    bytes32 secret,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Require the mode served by this settlement entry point; committed lookup supplies structural validity.
    _validate(terms, WrapperMode.CrossChain);
    // Read the exact signed terms for the selected escrow leg.
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    // Require the selected side to belong to the executing chain.
    _requireLocal(side);

    // Hash all ordered terms to recover the identity used by the committed record.
    trade = ProtocolHashing.tradeId(terms);
    // Check that the supplied preimage opens the settlement lock for this exact trade.
    _requireSecret(trade, lock, secret);

    // The applicable exclusive claim deadline has been reached.
    if (timestamp >= side.claimDeadline) revert ClaimWindowClosed();

    // A required custody instance is absent.
    if (htlc == address(0)) revert MissingHTLC();

    // Move the committed local leg to Claimed before calling custody.
    self.claim(trade, lock, ProtocolHashing.sideTag(party));

    // Pay this side to its signed claim destination; a transfer failure rolls back this call.
    ISwapHTLC(htlc).release(side, side.recipient);
  }

  /// @notice Reclaims one local cross-chain leg held by its dedicated HTLC.
  function reclaimCrossChainHTLC(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    CrossChainStateMachine.Layout storage self,
    // Dedicated custody clone indexed for the selected side.
    address htlc,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // True selects Alice's party side; false selects Bob's counterparty side.
    bool party,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Require the mode served by this settlement entry point; committed lookup supplies structural validity.
    _validate(terms, WrapperMode.CrossChain);
    // Read the exact signed terms for the selected escrow leg.
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    // Require the selected side to belong to the executing chain.
    _requireLocal(side);

    // The applicable inclusive reclaim release has not been reached.
    if (timestamp < side.reclaimRelease) revert ReclaimWindowClosed();

    // A required custody instance is absent.
    if (htlc == address(0)) revert MissingHTLC();

    // Hash all ordered terms to recover the identity used by the committed record.
    trade = ProtocolHashing.tradeId(terms);

    // Move the committed local leg to Reclaimed before calling custody.
    self.reclaim(trade, lock, ProtocolHashing.sideTag(party));

    // Pay this side to its signed reclaim destination; a transfer failure rolls back this call.
    ISwapHTLC(htlc).release(side, side.reclaimRecipient);
  }

  /// @notice Atomically claims both same-chain legs from their dedicated HTLCs.
  function claimSameChainHTLC(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Custody clone holding Alice's committed side.
    address partyHTLC,
    // Custody clone holding Bob's committed side.
    address counterpartyHTLC,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Preimage that must open the trade-bound settlement lock.
    bytes32 secret,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Validate the secret and claim window, then select the joint claim outcome.
    trade = selectSameChainClaim(self, terms, lock, secret, timestamp);
    // Require both custody addresses before attempting a two-sided payout.
    _requireTwoHTLCs(partyHTLC, counterpartyHTLC);

    // Release Alice's complete bundle to its signed claim destination.
    ISwapHTLC(partyHTLC).release(terms.partySide, terms.partySide.recipient);
    // Mark Alice complete only after her entire custody release succeeds.
    self.markSideComplete(trade, lock, ProtocolHashing.sideTag(true));

    // Release Bob's complete bundle to its signed claim destination.
    ISwapHTLC(counterpartyHTLC).release(terms.counterpartySide, terms.counterpartySide.recipient);
    // Mark Bob complete only after his entire custody release succeeds.
    self.markSideComplete(trade, lock, ProtocolHashing.sideTag(false));

    // Finalize Claimed only when all required side bits are complete.
    completeSelectedSameChainClaim(self, trade, lock);
  }

  /// @notice Reclaims the sole party HTLC when no counterparty commit was recorded.
  function reclaimSameChainPartyHTLC(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Custody clone holding Alice's committed side.
    address partyHTLC,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Select reclaim after the party release time and require a sole-party commitment.
    trade = selectSameChainPartyReclaim(self, terms, lock, timestamp);
    // A required custody instance is absent.
    if (partyHTLC == address(0)) revert MissingHTLC();

    // Return Alice's complete bundle to its signed reclaim destination.
    ISwapHTLC(partyHTLC).release(terms.partySide, terms.partySide.reclaimRecipient);
    // Mark Alice complete only after her entire custody release succeeds.
    self.markSideComplete(trade, lock, ProtocolHashing.sideTag(true));

    // Finalize Reclaimed only when all required side bits are complete.
    completeSelectedSameChainReclaim(self, trade, lock);
  }

  /// @notice Atomically reclaims both committed same-chain HTLCs.
  function reclaimSameChainBothHTLC(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Custody clone holding Alice's committed side.
    address partyHTLC,
    // Custody clone holding Bob's committed side.
    address counterpartyHTLC,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Require both committed sides and both release times before selecting joint reclaim.
    trade = selectSameChainBothReclaim(self, terms, lock, timestamp);
    // Require both custody addresses before attempting a two-sided payout.
    _requireTwoHTLCs(partyHTLC, counterpartyHTLC);

    // Return Alice's complete bundle to its signed reclaim destination.
    ISwapHTLC(partyHTLC).release(terms.partySide, terms.partySide.reclaimRecipient);
    // Mark Alice complete only after her entire custody release succeeds.
    self.markSideComplete(trade, lock, ProtocolHashing.sideTag(true));

    // Return Bob's complete bundle to its signed reclaim destination.
    ISwapHTLC(counterpartyHTLC).release(terms.counterpartySide, terms.counterpartySide.reclaimRecipient);
    // Mark Bob complete only after his entire custody release succeeds.
    self.markSideComplete(trade, lock, ProtocolHashing.sideTag(false));

    // Finalize Reclaimed only when all required side bits are complete.
    completeSelectedSameChainReclaim(self, trade, lock);
  }

  /// @notice Claims one local cross-chain leg with the trade-bound settlement preimage.
  function claimCrossChain(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    CrossChainStateMachine.Layout storage self,
    // Compatibility custody layout supplied by the caller for pooled-asset release paths.
    AssetCustody.Layout storage custody,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // True selects Alice's party side; false selects Bob's counterparty side.
    bool party,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Preimage that must open the trade-bound settlement lock.
    bytes32 secret,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Reject same-chain terms at the cross-chain settlement entry point.
    _validate(terms, WrapperMode.CrossChain);
    // Select the local escrow leg identified by the caller.
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    // Require the selected side to belong to the executing chain.
    _requireLocal(side);

    // Reconstruct the committed trade and verify its trade-bound HTLC preimage.
    trade = ProtocolHashing.tradeId(terms);
    // Check that the supplied preimage opens the settlement lock for this exact trade.
    _requireSecret(trade, lock, secret);

    // Claim is valid strictly before this leg claim deadline.
    if (timestamp >= side.claimDeadline) revert ClaimWindowClosed();

    // Make the terminal transition before releasing assets externally.
    self.claim(trade, lock, ProtocolHashing.sideTag(party));

    // Pay this side to its signed claim destination; a transfer failure rolls back this call.
    custody.release(side, side.recipient);
  }

  /// @notice Returns one local cross-chain leg after its reclaim release time.
  function reclaimCrossChain(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    CrossChainStateMachine.Layout storage self,
    // Compatibility custody layout supplied by the caller for pooled-asset release paths.
    AssetCustody.Layout storage custody,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // True selects Alice's party side; false selects Bob's counterparty side.
    bool party,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Select and validate the locally deployed cross-chain leg.
    _validate(terms, WrapperMode.CrossChain);
    // Read the exact signed terms for the selected escrow leg.
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    // Require the selected side to belong to the executing chain.
    _requireLocal(side);

    // Reclaim opens at the inclusive reclaim release time.
    if (timestamp < side.reclaimRelease) revert ReclaimWindowClosed();

    // Make the terminal transition before returning assets externally.
    trade = ProtocolHashing.tradeId(terms);

    // Move the committed local leg to Reclaimed before calling custody.
    self.reclaim(trade, lock, ProtocolHashing.sideTag(party));

    // Pay this side to its signed reclaim destination; a transfer failure rolls back this call.
    custody.release(side, side.reclaimRecipient);
  }

  /// @notice Atomically claims and releases both same-chain escrows.
  function claimSameChain(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Compatibility custody layout supplied by the caller for pooled-asset release paths.
    AssetCustody.Layout storage custody,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Preimage that must open the trade-bound settlement lock.
    bytes32 secret,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Validate the secret and claim window, then select the joint claim outcome.
    trade = selectSameChainClaim(self, terms, lock, secret, timestamp);

    // Select claim before either transfer; completion remains atomic in this compatibility path.
    // Release each escrow to the recipient fixed by its own side terms, then complete claim.
    custody.release(terms.partySide, terms.partySide.recipient);
    // Mark Alice complete only after her entire custody release succeeds.
    self.markSideComplete(trade, lock, ProtocolHashing.sideTag(true));

    // Release Bob's complete bundle to its signed claim destination.
    custody.release(terms.counterpartySide, terms.counterpartySide.recipient);
    // Mark Bob complete only after his entire custody release succeeds.
    self.markSideComplete(trade, lock, ProtocolHashing.sideTag(false));

    // Finalize Claimed only when all required side bits are complete.
    completeSelectedSameChainClaim(self, trade, lock);
  }

  /// @notice Reclaims the party escrow when no counterparty commit was recorded.
  function reclaimSameChainParty(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Compatibility custody layout supplied by the caller for pooled-asset release paths.
    AssetCustody.Layout storage custody,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Select reclaim after the party release time and require a sole-party commitment.
    trade = selectSameChainPartyReclaim(self, terms, lock, timestamp);

    // Return Alice's complete bundle to its signed reclaim destination.
    custody.release(terms.partySide, terms.partySide.reclaimRecipient);
    // Mark Alice complete only after her entire custody release succeeds.
    self.markSideComplete(trade, lock, ProtocolHashing.sideTag(true));

    // Finalize Reclaimed only when all required side bits are complete.
    completeSelectedSameChainReclaim(self, trade, lock);
  }

  /// @notice Atomically reclaims both committed escrows after both reclaim releases.
  function reclaimSameChainBoth(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    SameChainStateMachine.Layout storage self,
    // Compatibility custody layout supplied by the caller for pooled-asset release paths.
    AssetCustody.Layout storage custody,
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Caller-supplied current time; deployed wrappers use block.timestamp.
    uint256 timestamp
    // Apply the settlement transition and return its complete trade identifier.
  ) internal returns (bytes32 trade) {
    // Require both committed sides and both release times before selecting joint reclaim.
    trade = selectSameChainBothReclaim(self, terms, lock, timestamp);

    // Return Alice's complete bundle to its signed reclaim destination.
    custody.release(terms.partySide, terms.partySide.reclaimRecipient);
    // Mark Alice complete only after her entire custody release succeeds.
    self.markSideComplete(trade, lock, ProtocolHashing.sideTag(true));

    // Return Bob's complete bundle to its signed reclaim destination.
    custody.release(terms.counterpartySide, terms.counterpartySide.reclaimRecipient);
    // Mark Bob complete only after his entire custody release succeeds.
    self.markSideComplete(trade, lock, ProtocolHashing.sideTag(false));

    // Finalize Reclaimed only when all required side bits are complete.
    completeSelectedSameChainReclaim(self, trade, lock);
  }

  /// @dev Structural validity is established by the originating wrapper commit. Settlement's
  ///      admissible source-state lookup binds these complete terms to that record through TradeID
  ///      and the record-key hash, assuming canonical encoding and no relevant hash collision.
  ///      This mode check alone does not establish validity. See docs/settlement-validity.md.
  function _validate(ProtocolTerms memory terms, WrapperMode expected) private pure {
    // These terms select a different settlement mode.
    if (ProtocolHashing.mode(terms) != expected) revert InvalidSettlementMode();
  }

  // Reject settlement on a chain other than the side's signed chain.
  function _requireLocal(SideTerms memory side) private view {
    // The selected terms do not name the executing chain.
    if (side.chainId != block.chainid) revert InvalidLocalChain();
  }

  // Require both sides to execute on this chain for joint settlement.
  function _requireBothLocal(ProtocolTerms memory terms) private view {
    // Reject joint settlement if either signed chain differs from this deployment.
    if (terms.partySide.chainId != block.chainid || terms.counterpartySide.chainId != block.chainid) {
      // The selected terms do not name the executing chain.
      revert InvalidLocalChain();
    }
  }

  // Require both custody references before an atomic two-sided release.
  function _requireTwoHTLCs(address partyHTLC, address counterpartyHTLC) private pure {
    // A required custody instance is absent.
    if (partyHTLC == address(0) || counterpartyHTLC == address(0)) revert MissingHTLC();
  }

  // Verify that custody belongs to this wrapper and the exact committed side.
  function _requireHTLCBinding(
    // Dedicated custody clone indexed for the selected side.
    address htlc,
    // Identifier of the exact complete trade terms.
    bytes32 trade,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Ordered side whose assets or state this operation addresses.
    SideTag side,
    // Complete side terms used to verify custody binding.
    SideTerms memory sideTerms
    // Read custody binding without modifying contract storage.
  ) private view {
    // A required custody instance is absent.
    if (htlc == address(0) || htlc.code.length == 0) revert MissingHTLC();
    // Check all immutable custody bindings before allowing selected batch execution.
    if (
      // Require custody to name this wrapper as controller and this trade as its identity.
      ISwapHTLC(htlc).controller() != address(this) || ISwapHTLC(htlc).tradeId() != trade
        // Also require the exact settlement lock and ordered side.
        || ISwapHTLC(htlc).lock() != lock || ISwapHTLC(htlc).side() != side
        // Finally require custody's stored hash to bind every supplied signed side field.
        || ISwapHTLC(htlc).sideTermsHash() != ProtocolHashing.sideTermsHash(sideTerms)
      // The custody instance is not bound to this wrapper and exact side.
    ) revert InvalidHTLCBinding();
  }

  // Verify the settlement preimage under the full trade identifier.
  function _requireSecret(bytes32 trade, bytes32 lock, bytes32 secret) private pure {
    // Recompute the trade-bound settlement lock before accepting the supplied preimage.
    if (ProtocolHashing.settlementLock(trade, secret) != lock) {
      // The settlement preimage does not open this trade's lock.
      revert InvalidSettlementSecret();
    }
  }
}
