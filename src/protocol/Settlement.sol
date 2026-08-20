// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetCustody} from '../assets/AssetHandling.sol';
import {ProtocolHashing} from './ProtocolHashing.sol';
import {ProtocolTerms, SideTerms, WrapperMode} from './ProtocolTypes.sol';
import {CrossChainStateMachine} from './StateMachines.sol';
import {SameChainStateMachine} from './StateMachines.sol';

library Settlement {
  using AssetCustody for AssetCustody.Layout;
  using CrossChainStateMachine for CrossChainStateMachine.Layout;
  using SameChainStateMachine for SameChainStateMachine.Layout;

  error InvalidSettlementMode();
  error InvalidLocalChain();
  error InvalidSettlementSecret();
  error ClaimWindowClosed();
  error ReclaimWindowClosed();

  function claimCrossChain(
    CrossChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bool party,
    bytes32 lock,
    bytes32 secret,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    _validate(terms, WrapperMode.CrossChain);
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    _requireLocal(side);
    trade = ProtocolHashing.tradeId(terms);
    _requireSecret(trade, lock, secret);
    if (timestamp >= side.claimDeadline) revert ClaimWindowClosed();
    self.claim(trade, lock, ProtocolHashing.sideTag(party));
    custody.release(side, side.recipient);
  }

  function reclaimCrossChain(
    CrossChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bool party,
    bytes32 lock,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    _validate(terms, WrapperMode.CrossChain);
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    _requireLocal(side);
    if (timestamp < side.reclaimRelease) revert ReclaimWindowClosed();

    trade = ProtocolHashing.tradeId(terms);
    self.reclaim(trade, lock, ProtocolHashing.sideTag(party));
    custody.release(side, side.reclaimRecipient);
  }

  function claimSameChain(
    SameChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bytes32 lock,
    bytes32 secret,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    _validate(terms, WrapperMode.SameChain);
    _requireBothLocal(terms);
    trade = ProtocolHashing.tradeId(terms);
    _requireSecret(trade, lock, secret);
    uint256 deadline = terms.partySide.claimDeadline < terms.counterpartySide.claimDeadline
      ? terms.partySide.claimDeadline
      : terms.counterpartySide.claimDeadline;
    if (timestamp >= deadline) revert ClaimWindowClosed();

    self.claim(trade, lock);
    custody.release(terms.partySide, terms.partySide.recipient);
    custody.release(terms.counterpartySide, terms.counterpartySide.recipient);
  }

  function reclaimSameChainParty(
    SameChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bytes32 lock,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    _validate(terms, WrapperMode.SameChain);
    _requireBothLocal(terms);
    if (timestamp < terms.partySide.reclaimRelease) revert ReclaimWindowClosed();

    trade = ProtocolHashing.tradeId(terms);
    self.reclaimParty(trade, lock);
    custody.release(terms.partySide, terms.partySide.reclaimRecipient);
  }

  function reclaimSameChainBoth(
    SameChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bytes32 lock,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    _validate(terms, WrapperMode.SameChain);
    _requireBothLocal(terms);
    if (timestamp < terms.partySide.reclaimRelease || timestamp < terms.counterpartySide.reclaimRelease) {
      revert ReclaimWindowClosed();
    }

    trade = ProtocolHashing.tradeId(terms);
    self.reclaimBoth(trade, lock);
    custody.release(terms.partySide, terms.partySide.reclaimRecipient);
    custody.release(terms.counterpartySide, terms.counterpartySide.reclaimRecipient);
  }

  function _validate(ProtocolTerms memory terms, WrapperMode expected) private pure {
    if (ProtocolHashing.mode(terms) != expected) revert InvalidSettlementMode();
  }

  function _requireLocal(SideTerms memory side) private view {
    if (side.chainId != block.chainid) revert InvalidLocalChain();
  }

  function _requireBothLocal(ProtocolTerms memory terms) private view {
    if (terms.partySide.chainId != block.chainid || terms.counterpartySide.chainId != block.chainid) {
      revert InvalidLocalChain();
    }
  }

  function _requireSecret(bytes32 trade, bytes32 lock, bytes32 secret) private pure {
    if (ProtocolHashing.settlementLock(trade, secret) != lock) {
      revert InvalidSettlementSecret();
    }
  }
}
