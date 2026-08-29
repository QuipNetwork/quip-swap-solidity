// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CrossChainLegState, SameChainState, SideTag} from './ProtocolTypes.sol';

/// @title CrossChainStateMachine
/// @notice Stores and advances each locally deployed cross-chain escrow leg independently.
library CrossChainStateMachine {
  error InvalidCrossChainState(CrossChainLegState expected, CrossChainLegState actual);

  struct Layout {
    mapping(bytes32 recordKey => CrossChainLegState state) states;
  }

  /// @notice Derives storage identity from the trade, settlement lock, and local side.
  function recordKey(bytes32 tradeId, bytes32 lock, SideTag side) internal pure returns (bytes32) {
    return keccak256(abi.encode(tradeId, lock, side));
  }

  /// @notice Returns the current state of a cross-chain leg.
  function state(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock,
    SideTag side
  ) internal view returns (CrossChainLegState) {
    return self.states[recordKey(tradeId, lock, side)];
  }

  /// @notice Advances an unused leg to Committed.
  function commit(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal {
    // Resolve the exact local leg, reject replay, then record funded custody.
    bytes32 key = recordKey(tradeId, lock, side);
    _requireState(self.states[key], CrossChainLegState.Unused);
    self.states[key] = CrossChainLegState.Committed;
  }

  /// @notice Advances a committed leg to Claimed.
  function claim(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal {
    // Only a funded leg can make the terminal Claimed transition.
    bytes32 key = recordKey(tradeId, lock, side);
    _requireState(self.states[key], CrossChainLegState.Committed);
    self.states[key] = CrossChainLegState.Claimed;
  }

  /// @notice Advances a committed leg to Reclaimed.
  function reclaim(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal {
    // Only a funded leg can make the terminal Reclaimed transition.
    bytes32 key = recordKey(tradeId, lock, side);
    _requireState(self.states[key], CrossChainLegState.Committed);
    self.states[key] = CrossChainLegState.Reclaimed;
  }

  function _requireState(CrossChainLegState actual, CrossChainLegState expected) private pure {
    if (actual != expected) revert InvalidCrossChainState(expected, actual);
  }
}

/// @title SameChainStateMachine
/// @notice Stores the joint lifecycle of both escrows in a same-chain swap.
library SameChainStateMachine {
  error InvalidSameChainState(SameChainState expected, SameChainState actual);
  error SettlementNotPending(SameChainState actual);
  error UnexpectedSettlementSide(SideTag side);
  error SettlementSideAlreadyComplete(SideTag side);
  error SettlementIncomplete(uint8 expectedSides, uint8 completedSides);

  uint8 internal constant PARTY_SIDE_BIT = 1;
  uint8 internal constant COUNTERPARTY_SIDE_BIT = 2;
  uint8 internal constant BOTH_SIDE_BITS = PARTY_SIDE_BIT | COUNTERPARTY_SIDE_BIT;

  struct Record {
    SameChainState state;
    uint8 expectedSides;
    uint8 completedSides;
  }

  struct Layout {
    mapping(bytes32 recordKey => Record record) records;
  }

  /// @notice Derives storage identity from the trade and settlement lock.
  function recordKey(bytes32 tradeId, bytes32 lock) internal pure returns (bytes32) {
    return keccak256(abi.encode(tradeId, lock));
  }

  /// @notice Returns the current joint state of a same-chain swap.
  function state(Layout storage self, bytes32 tradeId, bytes32 lock) internal view returns (SameChainState) {
    return self.records[recordKey(tradeId, lock)].state;
  }

  /// @notice Returns the required and completed side bitmaps for settlement execution.
  function settlementProgress(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock
  ) internal view returns (uint8 expectedSides, uint8 completedSides) {
    Record storage record = self.records[recordKey(tradeId, lock)];
    return (record.expectedSides, record.completedSides);
  }

  /// @notice Records the first, party-side commit.
  function commitParty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    // The party commit creates the joint record.
    bytes32 key = recordKey(tradeId, lock);
    Record storage record = self.records[key];
    _requireState(record.state, SameChainState.Unused);
    record.state = SameChainState.PartyCommitted;
  }

  /// @notice Records the counterparty commit after the party commit.
  function commitCounterparty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    // The counterparty may fund only after the party escrow exists.
    bytes32 key = recordKey(tradeId, lock);
    Record storage record = self.records[key];
    _requireState(record.state, SameChainState.PartyCommitted);
    record.state = SameChainState.BothCommitted;
  }

  /// @notice Irreversibly selects claim after both sides have committed.
  function selectClaim(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    Record storage record = self.records[key];
    _requireState(record.state, SameChainState.BothCommitted);
    record.state = SameChainState.ClaimPending;
    record.expectedSides = BOTH_SIDE_BITS;
    record.completedSides = 0;
  }

  /// @notice Irreversibly selects reclaim when only the party side committed.
  function selectReclaimParty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    Record storage record = self.records[key];
    _requireState(record.state, SameChainState.PartyCommitted);
    record.state = SameChainState.ReclaimPending;
    record.expectedSides = PARTY_SIDE_BIT;
    record.completedSides = 0;
  }

  /// @notice Irreversibly selects reclaim after both sides have committed.
  function selectReclaimBoth(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    Record storage record = self.records[key];
    _requireState(record.state, SameChainState.BothCommitted);
    record.state = SameChainState.ReclaimPending;
    record.expectedSides = BOTH_SIDE_BITS;
    record.completedSides = 0;
  }

  /// @notice Marks one required side complete while preserving the selected pending outcome.
  function markSideComplete(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal {
    Record storage record = self.records[recordKey(tradeId, lock)];
    _requirePendingSide(record, side);
    uint8 bit = side == SideTag.Party ? PARTY_SIDE_BIT : COUNTERPARTY_SIDE_BIT;
    record.completedSides |= bit;
  }

  /// @notice Requires a side to be selected, required, and not yet complete without mutating it.
  function requirePendingSide(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal view {
    _requirePendingSide(self.records[recordKey(tradeId, lock)], side);
  }

  function _requirePendingSide(Record storage record, SideTag side) private view {
    if (record.state != SameChainState.ClaimPending && record.state != SameChainState.ReclaimPending) {
      revert SettlementNotPending(record.state);
    }
    uint8 bit = side == SideTag.Party ? PARTY_SIDE_BIT : COUNTERPARTY_SIDE_BIT;
    if (record.expectedSides & bit == 0) revert UnexpectedSettlementSide(side);
    if (record.completedSides & bit != 0) revert SettlementSideAlreadyComplete(side);
  }

  /// @notice Completes a previously selected claim.
  function completeClaim(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    Record storage record = self.records[key];
    _requireState(record.state, SameChainState.ClaimPending);
    _requireComplete(record);
    record.state = SameChainState.Claimed;
  }

  /// @notice Completes a previously selected reclaim.
  function completeReclaim(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    Record storage record = self.records[key];
    _requireState(record.state, SameChainState.ReclaimPending);
    _requireComplete(record);
    record.state = SameChainState.Reclaimed;
  }

  function _requireComplete(Record storage record) private view {
    if (record.completedSides != record.expectedSides) {
      revert SettlementIncomplete(record.expectedSides, record.completedSides);
    }
  }

  function _requireState(SameChainState actual, SameChainState expected) private pure {
    if (actual != expected) revert InvalidSameChainState(expected, actual);
  }
}
