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

  struct Layout {
    mapping(bytes32 recordKey => SameChainState state) states;
  }

  /// @notice Derives storage identity from the trade and settlement lock.
  function recordKey(bytes32 tradeId, bytes32 lock) internal pure returns (bytes32) {
    return keccak256(abi.encode(tradeId, lock));
  }

  /// @notice Returns the current joint state of a same-chain swap.
  function state(Layout storage self, bytes32 tradeId, bytes32 lock) internal view returns (SameChainState) {
    return self.states[recordKey(tradeId, lock)];
  }

  /// @notice Records the first, party-side commit.
  function commitParty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    // The party commit creates the joint record.
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.Unused);
    self.states[key] = SameChainState.PartyCommitted;
  }

  /// @notice Records the counterparty commit after the party commit.
  function commitCounterparty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    // The counterparty may fund only after the party escrow exists.
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.PartyCommitted);
    self.states[key] = SameChainState.BothCommitted;
  }

  /// @notice Irreversibly selects claim after both sides have committed.
  function selectClaim(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.BothCommitted);
    self.states[key] = SameChainState.ClaimPending;
  }

  /// @notice Irreversibly selects reclaim when only the party side committed.
  function selectReclaimParty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.PartyCommitted);
    self.states[key] = SameChainState.ReclaimPending;
  }

  /// @notice Irreversibly selects reclaim after both sides have committed.
  function selectReclaimBoth(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.BothCommitted);
    self.states[key] = SameChainState.ReclaimPending;
  }

  /// @notice Completes a previously selected claim.
  function completeClaim(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.ClaimPending);
    self.states[key] = SameChainState.Claimed;
  }

  /// @notice Completes a previously selected reclaim.
  function completeReclaim(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.ReclaimPending);
    self.states[key] = SameChainState.Reclaimed;
  }

  function _requireState(SameChainState actual, SameChainState expected) private pure {
    if (actual != expected) revert InvalidSameChainState(expected, actual);
  }
}
