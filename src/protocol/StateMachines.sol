// SPDX-License-Identifier: UNLICENSE
// Pin the compiler version used for these encodings and contract semantics.
pragma solidity 0.8.33;

// Import unused, committed, and terminal local-leg states; Joint commit, pending settlement, and terminal states;
// Canonical party and counterparty side tags.
import {CrossChainLegState, SameChainState, SideTag} from './ProtocolTypes.sol';

/// @title CrossChainStateMachine
/// @notice Stores and advances each locally deployed cross-chain escrow leg independently.
library CrossChainStateMachine {
  // The local leg is not in the required source state.
  error InvalidCrossChainState(CrossChainLegState expected, CrossChainLegState actual);

  // Group storage owned by the calling wrapper.
  struct Layout {
    // Index lifecycle records by the complete hashed record identity.
    mapping(bytes32 recordKey => CrossChainLegState state) states;
  }

  /// @notice Derives storage identity from the trade, settlement lock, and local side.
  function recordKey(bytes32 tradeId, bytes32 lock, SideTag side) internal pure returns (bytes32) {
    // Hash the complete local-leg identity with unambiguous ABI encoding.
    return keccak256(abi.encode(tradeId, lock, side));
  }

  /// @notice Returns the current state of a cross-chain leg.
  function state(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    Layout storage self,
    // Hash of the complete ordered terms.
    bytes32 tradeId,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Ordered side whose assets or state this operation addresses.
    SideTag side
    // Read the selected local leg lifecycle without changing storage.
  ) internal view returns (CrossChainLegState) {
    // Read the local leg state; an absent mapping entry is Unused.
    return self.states[recordKey(tradeId, lock, side)];
  }

  /// @notice Advances an unused leg to Committed.
  function commit(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal {
    // Resolve the exact local leg, reject replay, then record funded custody.
    bytes32 key = recordKey(tradeId, lock, side);
    // Require a fresh record so this commitment cannot replay.
    _requireState(self.states[key], CrossChainLegState.Unused);

    // This local leg has committed custody.
    self.states[key] = CrossChainLegState.Committed;
  }

  /// @notice Advances a committed leg to Claimed.
  function claim(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal {
    // Only a funded leg can make the terminal Claimed transition.
    bytes32 key = recordKey(tradeId, lock, side);
    // Require live committed custody; terminal records cannot settle again.
    _requireState(self.states[key], CrossChainLegState.Committed);

    // Record Claimed before payout; the calling transaction must revert this transition if payout fails.
    self.states[key] = CrossChainLegState.Claimed;
  }

  /// @notice Advances a committed leg to Reclaimed.
  function reclaim(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal {
    // Only a funded leg can make the terminal Reclaimed transition.
    bytes32 key = recordKey(tradeId, lock, side);
    // Require live committed custody; terminal records cannot settle again.
    _requireState(self.states[key], CrossChainLegState.Committed);

    // Record Reclaimed before payout; the calling transaction must revert this transition if payout fails.
    self.states[key] = CrossChainLegState.Reclaimed;
  }

  // Reject a lifecycle transition whose stored source state is not the expected one.
  function _requireState(CrossChainLegState actual, CrossChainLegState expected) private pure {
    // The local leg is not in the required source state.
    if (actual != expected) revert InvalidCrossChainState(expected, actual);
  }
}

/// @title SameChainStateMachine
/// @notice Stores the joint lifecycle of both escrows in a same-chain swap.
library SameChainStateMachine {
  // The joint record is not in the required source state.
  error InvalidSameChainState(SameChainState expected, SameChainState actual);
  // No claim or reclaim outcome is pending execution.
  error SettlementNotPending(SameChainState actual);
  // The selected outcome does not require this side.
  error UnexpectedSettlementSide(SideTag side);
  // This side has already completed its payout.
  error SettlementSideAlreadyComplete(SideTag side);
  // Not all required side payouts have completed.
  error SettlementIncomplete(uint8 expectedSides, uint8 completedSides);

  // Reserve the low bit for Alice's required/completed status.
  uint8 internal constant PARTY_SIDE_BIT = 1;
  // Reserve the second bit for Bob's required/completed status.
  uint8 internal constant COUNTERPARTY_SIDE_BIT = 2;
  // Combine both side bits for a two-sided settlement.
  uint8 internal constant BOTH_SIDE_BITS = PARTY_SIDE_BIT | COUNTERPARTY_SIDE_BIT;

  // Store the joint lifecycle and side-completion masks.
  struct Record {
    // Current joint lifecycle state stored for this trade and lock.
    SameChainState state;
    // Bitmap of sides required by the selected outcome.
    uint8 expectedSides;
    // Bitmap of sides whose full payouts have completed.
    uint8 completedSides;
  }

  // Group storage owned by the calling wrapper.
  struct Layout {
    // Index lifecycle records by the complete hashed record identity.
    mapping(bytes32 recordKey => Record record) records;
  }

  /// @notice Derives storage identity from the trade and settlement lock.
  function recordKey(bytes32 tradeId, bytes32 lock) internal pure returns (bytes32) {
    // Hash the joint trade identity with unambiguous ABI encoding.
    return keccak256(abi.encode(tradeId, lock));
  }

  /// @notice Returns the current joint state of a same-chain swap.
  function state(Layout storage self, bytes32 tradeId, bytes32 lock) internal view returns (SameChainState) {
    // Read the joint state; an absent mapping entry is Unused.
    return self.records[recordKey(tradeId, lock)].state;
  }

  /// @notice Returns the required and completed side bitmaps for settlement execution.
  function settlementProgress(
    // Storage layout owned by the calling wrapper; library transitions update it in place.
    Layout storage self,
    // Hash of the complete ordered terms.
    bytes32 tradeId,
    // Trade-bound settlement hash lock.
    bytes32 lock
    // Expose required and completed side masks without modifying storage.
  ) internal view returns (uint8 expectedSides, uint8 completedSides) {
    // Borrow the stored joint record so subsequent updates persist in wrapper storage.
    Record storage record = self.records[recordKey(tradeId, lock)];
    // Expose required and completed side masks without changing the record.
    return (record.expectedSides, record.completedSides);
  }

  /// @notice Records the first, party-side commit.
  function commitParty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    // The party commit creates the joint record.
    bytes32 key = recordKey(tradeId, lock);
    // Borrow the stored joint record so subsequent updates persist in wrapper storage.
    Record storage record = self.records[key];
    // Require a fresh record so this commitment cannot replay.
    _requireState(record.state, SameChainState.Unused);

    // Only Alice's commitment has been recorded.
    record.state = SameChainState.PartyCommitted;
  }

  /// @notice Records the counterparty commit after the party commit.
  function commitCounterparty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    // The counterparty may fund only after the party escrow exists.
    bytes32 key = recordKey(tradeId, lock);
    // Borrow the stored joint record so subsequent updates persist in wrapper storage.
    Record storage record = self.records[key];
    // Require Alice's sole commitment as the source of this transition.
    _requireState(record.state, SameChainState.PartyCommitted);

    // Both ordered commitments have been recorded.
    record.state = SameChainState.BothCommitted;
  }

  /// @notice Irreversibly selects claim after both sides have committed.
  function selectClaim(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    // Resolve the lifecycle storage key without allowing another trade or side to alias it.
    bytes32 key = recordKey(tradeId, lock);
    // Borrow the stored joint record so subsequent updates persist in wrapper storage.
    Record storage record = self.records[key];
    // Require both commitments before selecting a two-sided outcome.
    _requireState(record.state, SameChainState.BothCommitted);

    // Claim was selected irreversibly; required payouts remain to be completed.
    record.state = SameChainState.ClaimPending;

    // Both funded sides must finish before this selected outcome becomes terminal.
    record.expectedSides = BOTH_SIDE_BITS;
    // Start settlement with neither required side released.
    record.completedSides = 0;
  }

  /// @notice Irreversibly selects reclaim when only the party side committed.
  function selectReclaimParty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    // Resolve the lifecycle storage key without allowing another trade or side to alias it.
    bytes32 key = recordKey(tradeId, lock);
    // Borrow the stored joint record so subsequent updates persist in wrapper storage.
    Record storage record = self.records[key];
    // Require Alice's sole commitment as the source of this transition.
    _requireState(record.state, SameChainState.PartyCommitted);

    // Reclaim was selected irreversibly; required payouts remain to be completed.
    record.state = SameChainState.ReclaimPending;

    // Only Alice funded, so only her side is required for recovery.
    record.expectedSides = PARTY_SIDE_BIT;
    // Start settlement with neither required side released.
    record.completedSides = 0;
  }

  /// @notice Irreversibly selects reclaim after both sides have committed.
  function selectReclaimBoth(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    // Resolve the lifecycle storage key without allowing another trade or side to alias it.
    bytes32 key = recordKey(tradeId, lock);
    // Borrow the stored joint record so subsequent updates persist in wrapper storage.
    Record storage record = self.records[key];
    // Require both commitments before selecting a two-sided outcome.
    _requireState(record.state, SameChainState.BothCommitted);

    // Reclaim was selected irreversibly; required payouts remain to be completed.
    record.state = SameChainState.ReclaimPending;

    // Both funded sides must finish before this selected outcome becomes terminal.
    record.expectedSides = BOTH_SIDE_BITS;
    // Start settlement with neither required side released.
    record.completedSides = 0;
  }

  /// @notice Marks one required side complete while preserving the selected pending outcome.
  function markSideComplete(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal {
    // Borrow the stored joint record so subsequent updates persist in wrapper storage.
    Record storage record = self.records[recordKey(tradeId, lock)];
    // Require a pending outcome and a required side that has not already completed.
    _requirePendingSide(record, side);

    // Select the bit corresponding to the requested side.
    uint8 bit = side == SideTag.Party ? PARTY_SIDE_BIT : COUNTERPARTY_SIDE_BIT;
    // Set this side's completion bit without erasing progress on the other side.
    record.completedSides |= bit;
  }

  /// @notice Requires a side to be selected, required, and not yet complete without mutating it.
  function requirePendingSide(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal view {
    // Require a pending outcome and a required side that has not already completed.
    _requirePendingSide(self.records[recordKey(tradeId, lock)], side);
  }

  // Require a selected outcome and an unfinished side included in its completion mask.
  function _requirePendingSide(Record storage record, SideTag side) private view {
    // A side can execute only after an irreversible settlement outcome has been selected.
    if (record.state != SameChainState.ClaimPending && record.state != SameChainState.ReclaimPending) {
      // No claim or reclaim outcome is pending execution.
      revert SettlementNotPending(record.state);
    }

    // Select the bit corresponding to the requested side.
    uint8 bit = side == SideTag.Party ? PARTY_SIDE_BIT : COUNTERPARTY_SIDE_BIT;

    // The selected outcome does not require this side.
    if (record.expectedSides & bit == 0) revert UnexpectedSettlementSide(side);
    // This side has already completed its payout.
    if (record.completedSides & bit != 0) revert SettlementSideAlreadyComplete(side);
  }

  /// @notice Completes a previously selected claim.
  function completeClaim(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    // Resolve the lifecycle storage key without allowing another trade or side to alias it.
    bytes32 key = recordKey(tradeId, lock);
    // Borrow the stored joint record so subsequent updates persist in wrapper storage.
    Record storage record = self.records[key];
    // Require the previously selected claim outcome.
    _requireState(record.state, SameChainState.ClaimPending);
    // Require all selected side payouts to have completed.
    _requireComplete(record);

    // All payouts required by this claim have completed.
    record.state = SameChainState.Claimed;
  }

  /// @notice Completes a previously selected reclaim.
  function completeReclaim(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    // Resolve the lifecycle storage key without allowing another trade or side to alias it.
    bytes32 key = recordKey(tradeId, lock);
    // Borrow the stored joint record so subsequent updates persist in wrapper storage.
    Record storage record = self.records[key];
    // Require the previously selected reclaim outcome.
    _requireState(record.state, SameChainState.ReclaimPending);
    // Require all selected side payouts to have completed.
    _requireComplete(record);

    // All payouts required by this reclaim have completed.
    record.state = SameChainState.Reclaimed;
  }

  // Prevent a terminal transition until all required side payouts have completed.
  function _requireComplete(Record storage record) private view {
    // Require the completed bitmap to match the selected outcome's required bitmap.
    if (record.completedSides != record.expectedSides) {
      // Not all required side payouts have completed.
      revert SettlementIncomplete(record.expectedSides, record.completedSides);
    }
  }

  // Reject a lifecycle transition whose stored source state is not the expected one.
  function _requireState(SameChainState actual, SameChainState expected) private pure {
    // The joint record is not in the required source state.
    if (actual != expected) revert InvalidSameChainState(expected, actual);
  }
}
