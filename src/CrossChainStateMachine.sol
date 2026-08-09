// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CrossChainLegState, SideTag} from './ProtocolTypes.sol';

library CrossChainStateMachine {
  error InvalidCrossChainState(CrossChainLegState expected, CrossChainLegState actual);
  error CrossChainBindingMismatch();

  struct LegRecord {
    CrossChainLegState state;
    bytes32 bindingHash;
  }

  struct Layout {
    mapping(bytes32 recordKey => LegRecord record) records;
  }

  function recordKey(bytes32 tradeId, bytes32 lock, SideTag side) internal pure returns (bytes32) {
    return keccak256(abi.encode(tradeId, lock, side));
  }

  function bindingHash(
    bytes32 tradeId,
    bytes32 lock,
    SideTag side,
    bytes32 termsHash,
    bytes32 assetHash
  ) internal pure returns (bytes32) {
    return keccak256(abi.encode(tradeId, lock, side, termsHash, assetHash));
  }

  function record(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock,
    SideTag side
  ) internal view returns (LegRecord memory) {
    return self.records[recordKey(tradeId, lock, side)];
  }

  function commit(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock,
    SideTag side,
    bytes32 termsHash,
    bytes32 assetHash
  ) internal {
    LegRecord storage stored = self.records[recordKey(tradeId, lock, side)];
    _requireState(stored.state, CrossChainLegState.Unused);
    stored.bindingHash = bindingHash(tradeId, lock, side, termsHash, assetHash);
    stored.state = CrossChainLegState.Committed;
  }

  function claim(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock,
    SideTag side,
    bytes32 termsHash,
    bytes32 assetHash
  ) internal {
    LegRecord storage stored = self.records[recordKey(tradeId, lock, side)];
    _requireState(stored.state, CrossChainLegState.Committed);
    _requireBinding(stored.bindingHash, bindingHash(tradeId, lock, side, termsHash, assetHash));
    stored.state = CrossChainLegState.Claimed;
  }

  function reclaim(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock,
    SideTag side,
    bytes32 termsHash,
    bytes32 assetHash
  ) internal {
    LegRecord storage stored = self.records[recordKey(tradeId, lock, side)];
    _requireState(stored.state, CrossChainLegState.Committed);
    _requireBinding(stored.bindingHash, bindingHash(tradeId, lock, side, termsHash, assetHash));
    stored.state = CrossChainLegState.Reclaimed;
  }

  function _requireState(CrossChainLegState actual, CrossChainLegState expected) private pure {
    if (actual != expected) revert InvalidCrossChainState(expected, actual);
  }

  function _requireBinding(bytes32 actual, bytes32 expected) private pure {
    if (actual != expected) revert CrossChainBindingMismatch();
  }
}
