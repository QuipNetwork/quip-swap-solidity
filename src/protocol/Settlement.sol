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
  ) internal {
    _validate(terms, WrapperMode.CrossChain);
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    _requireLocal(side);
    _requireSecret(terms, lock, secret);
    if (timestamp >= side.claimDeadline) revert ClaimWindowClosed();

    bytes32 trade = ProtocolHashing.tradeId(terms);
    self.claim(trade, lock, ProtocolHashing.sideTag(party), trade, ProtocolHashing.assetHash(side));
    custody.release(side, side.recipient);
  }

  function reclaimCrossChain(
    CrossChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bool party,
    bytes32 lock,
    uint256 timestamp
  ) internal {
    _validate(terms, WrapperMode.CrossChain);
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    _requireLocal(side);
    if (timestamp < side.reclaimRelease) revert ReclaimWindowClosed();

    bytes32 trade = ProtocolHashing.tradeId(terms);
    self.reclaim(trade, lock, ProtocolHashing.sideTag(party), trade, ProtocolHashing.assetHash(side));
    custody.release(side, side.reclaimRecipient);
  }

  function claimSameChain(
    SameChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bytes32 lock,
    bytes32 secret,
    uint256 timestamp
  ) internal {
    _validate(terms, WrapperMode.SameChain);
    _requireBothLocal(terms);
    _requireSecret(terms, lock, secret);
    uint256 deadline = terms.partySide.claimDeadline < terms.counterpartySide.claimDeadline
      ? terms.partySide.claimDeadline
      : terms.counterpartySide.claimDeadline;
    if (timestamp >= deadline) revert ClaimWindowClosed();

    bytes32 trade = ProtocolHashing.tradeId(terms);
    self.claim(
      trade, lock, trade, ProtocolHashing.assetHash(terms.partySide), ProtocolHashing.assetHash(terms.counterpartySide)
    );
    custody.release(terms.partySide, terms.partySide.recipient);
    custody.release(terms.counterpartySide, terms.counterpartySide.recipient);
  }

  function reclaimSameChainParty(
    SameChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bytes32 lock,
    uint256 timestamp
  ) internal {
    _validate(terms, WrapperMode.SameChain);
    _requireBothLocal(terms);
    if (timestamp < terms.partySide.reclaimRelease) revert ReclaimWindowClosed();

    bytes32 trade = ProtocolHashing.tradeId(terms);
    self.reclaimParty(
      trade, lock, trade, ProtocolHashing.assetHash(terms.partySide), ProtocolHashing.assetHash(terms.counterpartySide)
    );
    custody.release(terms.partySide, terms.partySide.reclaimRecipient);
  }

  function reclaimSameChainBoth(
    SameChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bytes32 lock,
    uint256 timestamp
  ) internal {
    _validate(terms, WrapperMode.SameChain);
    _requireBothLocal(terms);
    if (timestamp < terms.partySide.reclaimRelease || timestamp < terms.counterpartySide.reclaimRelease) {
      revert ReclaimWindowClosed();
    }

    bytes32 trade = ProtocolHashing.tradeId(terms);
    self.reclaimBoth(
      trade, lock, trade, ProtocolHashing.assetHash(terms.partySide), ProtocolHashing.assetHash(terms.counterpartySide)
    );
    custody.release(terms.partySide, terms.partySide.reclaimRecipient);
    custody.release(terms.counterpartySide, terms.counterpartySide.reclaimRecipient);
  }

  function _validate(ProtocolTerms memory terms, WrapperMode expected) private pure {
    ProtocolHashing.validateTerms(terms);
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

  function _requireSecret(ProtocolTerms memory terms, bytes32 lock, bytes32 secret) private pure {
    if (ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), secret) != lock) {
      revert InvalidSettlementSecret();
    }
  }
}
