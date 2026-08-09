// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {SameChainState} from './ProtocolTypes.sol';

library SameChainStateMachine {
  error InvalidSameChainState(SameChainState expected, SameChainState actual);
  error SameChainBindingMismatch();

  struct TradeRecord {
    SameChainState state;
    bytes32 bindingHash;
  }

  struct Layout {
    mapping(bytes32 recordKey => TradeRecord record) records;
  }

  function recordKey(bytes32 tradeId, bytes32 lock) internal pure returns (bytes32) {
    return keccak256(abi.encode(tradeId, lock));
  }

  function bindingHash(
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) internal pure returns (bytes32) {
    return keccak256(abi.encode(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash));
  }

  function record(Layout storage self, bytes32 tradeId, bytes32 lock) internal view returns (TradeRecord memory) {
    return self.records[recordKey(tradeId, lock)];
  }

  function commitParty(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) internal {
    TradeRecord storage stored = self.records[recordKey(tradeId, lock)];
    _requireState(stored.state, SameChainState.Unused);
    stored.bindingHash = bindingHash(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash);
    stored.state = SameChainState.PartyCommitted;
  }

  function commitCounterparty(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) internal {
    TradeRecord storage stored = self.records[recordKey(tradeId, lock)];
    _requireState(stored.state, SameChainState.PartyCommitted);
    _requireBinding(stored.bindingHash, bindingHash(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash));
    stored.state = SameChainState.BothCommitted;
  }

  function claim(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) internal {
    TradeRecord storage stored = self.records[recordKey(tradeId, lock)];
    _requireState(stored.state, SameChainState.BothCommitted);
    _requireBinding(stored.bindingHash, bindingHash(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash));
    stored.state = SameChainState.Claimed;
  }

  function reclaimParty(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) internal {
    TradeRecord storage stored = self.records[recordKey(tradeId, lock)];
    _requireState(stored.state, SameChainState.PartyCommitted);
    _requireBinding(stored.bindingHash, bindingHash(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash));
    stored.state = SameChainState.Reclaimed;
  }

  function reclaimBoth(
    Layout storage self,
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) internal {
    TradeRecord storage stored = self.records[recordKey(tradeId, lock)];
    _requireState(stored.state, SameChainState.BothCommitted);
    _requireBinding(stored.bindingHash, bindingHash(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash));
    stored.state = SameChainState.Reclaimed;
  }

  function _requireState(SameChainState actual, SameChainState expected) private pure {
    if (actual != expected) revert InvalidSameChainState(expected, actual);
  }

  function _requireBinding(bytes32 actual, bytes32 expected) private pure {
    if (actual != expected) revert SameChainBindingMismatch();
  }
}
