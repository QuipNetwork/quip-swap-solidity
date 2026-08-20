// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CrossChainLegState, SameChainState, SideTag} from './ProtocolTypes.sol';

library CrossChainStateMachine {
  error InvalidCrossChainState(CrossChainLegState expected, CrossChainLegState actual);

  struct Layout {
    mapping(bytes32 recordKey => CrossChainLegState state) states;
  }

  function recordKey(bytes32 tradeId, bytes32 lock, SideTag side) internal pure returns (bytes32) {
    return keccak256(abi.encode(tradeId, lock, side));
  }

  function state(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock,
    SideTag side
  ) internal view returns (CrossChainLegState) {
    return self.states[recordKey(tradeId, lock, side)];
  }

  function commit(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal {
    bytes32 key = recordKey(tradeId, lock, side);
    _requireState(self.states[key], CrossChainLegState.Unused);
    self.states[key] = CrossChainLegState.Committed;
  }

  function claim(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal {
    bytes32 key = recordKey(tradeId, lock, side);
    _requireState(self.states[key], CrossChainLegState.Committed);
    self.states[key] = CrossChainLegState.Claimed;
  }

  function reclaim(Layout storage self, bytes32 tradeId, bytes32 lock, SideTag side) internal {
    bytes32 key = recordKey(tradeId, lock, side);
    _requireState(self.states[key], CrossChainLegState.Committed);
    self.states[key] = CrossChainLegState.Reclaimed;
  }

  function _requireState(CrossChainLegState actual, CrossChainLegState expected) private pure {
    if (actual != expected) revert InvalidCrossChainState(expected, actual);
  }
}

library SameChainStateMachine {
  error InvalidSameChainState(SameChainState expected, SameChainState actual);

  struct Layout {
    mapping(bytes32 recordKey => SameChainState state) states;
  }

  function recordKey(bytes32 tradeId, bytes32 lock) internal pure returns (bytes32) {
    return keccak256(abi.encode(tradeId, lock));
  }

  function state(Layout storage self, bytes32 tradeId, bytes32 lock) internal view returns (SameChainState) {
    return self.states[recordKey(tradeId, lock)];
  }

  function commitParty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.Unused);
    self.states[key] = SameChainState.PartyCommitted;
  }

  function commitCounterparty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.PartyCommitted);
    self.states[key] = SameChainState.BothCommitted;
  }

  function claim(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.BothCommitted);
    self.states[key] = SameChainState.Claimed;
  }

  function reclaimParty(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.PartyCommitted);
    self.states[key] = SameChainState.Reclaimed;
  }

  function reclaimBoth(Layout storage self, bytes32 tradeId, bytes32 lock) internal {
    bytes32 key = recordKey(tradeId, lock);
    _requireState(self.states[key], SameChainState.BothCommitted);
    self.states[key] = SameChainState.Reclaimed;
  }

  function _requireState(SameChainState actual, SameChainState expected) private pure {
    if (actual != expected) revert InvalidSameChainState(expected, actual);
  }
}
