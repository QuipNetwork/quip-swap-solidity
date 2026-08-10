// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CrossChainStateMachine} from './CrossChainStateMachine.sol';
import {ProtocolHashing} from './ProtocolHashing.sol';
import {ProtocolTerms, SideTerms, TimingPolicy, WrapperMode} from './ProtocolTypes.sol';
import {SameChainStateMachine} from './SameChainStateMachine.sol';
import {TermsLib} from './TermsLib.sol';

library Settlement {
  using CrossChainStateMachine for CrossChainStateMachine.Layout;
  using SameChainStateMachine for SameChainStateMachine.Layout;

  error InvalidSettlementMode();
  error InvalidLocalChain();
  error InvalidSettlementSecret();
  error ClaimWindowClosed();
  error ReclaimWindowClosed();

  function claimCrossChain(
    CrossChainStateMachine.Layout storage self,
    ProtocolTerms memory terms,
    TimingPolicy memory policy,
    bool party,
    bytes32 lock,
    bytes32 secret,
    uint256 timestamp
  ) internal {
    _validate(terms, policy, WrapperMode.CrossChain);
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    _requireLocal(side);
    _requireSecret(terms, lock, secret);
    if (timestamp >= side.claimDeadline) revert ClaimWindowClosed();

    bytes32 trade = ProtocolHashing.tradeId(terms);
    self.claim(trade, lock, ProtocolHashing.sideTag(party), trade, ProtocolHashing.assetHash(side));
    _transfer(side, side.recipient);
  }

  function reclaimCrossChain(
    CrossChainStateMachine.Layout storage self,
    ProtocolTerms memory terms,
    TimingPolicy memory policy,
    bool party,
    bytes32 lock,
    uint256 timestamp
  ) internal {
    _validate(terms, policy, WrapperMode.CrossChain);
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    _requireLocal(side);
    if (timestamp < side.reclaimRelease) revert ReclaimWindowClosed();

    bytes32 trade = ProtocolHashing.tradeId(terms);
    self.reclaim(trade, lock, ProtocolHashing.sideTag(party), trade, ProtocolHashing.assetHash(side));
    _transfer(side, side.reclaimRecipient);
  }

  function claimSameChain(
    SameChainStateMachine.Layout storage self,
    ProtocolTerms memory terms,
    TimingPolicy memory policy,
    bytes32 lock,
    bytes32 secret,
    uint256 timestamp
  ) internal {
    _validate(terms, policy, WrapperMode.SameChain);
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
    _transfer(terms.partySide, terms.partySide.recipient);
    _transfer(terms.counterpartySide, terms.counterpartySide.recipient);
  }

  function reclaimSameChainParty(
    SameChainStateMachine.Layout storage self,
    ProtocolTerms memory terms,
    TimingPolicy memory policy,
    bytes32 lock,
    uint256 timestamp
  ) internal {
    _validate(terms, policy, WrapperMode.SameChain);
    _requireBothLocal(terms);
    if (timestamp < terms.partySide.reclaimRelease) revert ReclaimWindowClosed();

    bytes32 trade = ProtocolHashing.tradeId(terms);
    self.reclaimParty(
      trade, lock, trade, ProtocolHashing.assetHash(terms.partySide), ProtocolHashing.assetHash(terms.counterpartySide)
    );
    _transfer(terms.partySide, terms.partySide.reclaimRecipient);
  }

  function reclaimSameChainBoth(
    SameChainStateMachine.Layout storage self,
    ProtocolTerms memory terms,
    TimingPolicy memory policy,
    bytes32 lock,
    uint256 timestamp
  ) internal {
    _validate(terms, policy, WrapperMode.SameChain);
    _requireBothLocal(terms);
    if (timestamp < terms.partySide.reclaimRelease || timestamp < terms.counterpartySide.reclaimRelease) {
      revert ReclaimWindowClosed();
    }

    bytes32 trade = ProtocolHashing.tradeId(terms);
    self.reclaimBoth(
      trade, lock, trade, ProtocolHashing.assetHash(terms.partySide), ProtocolHashing.assetHash(terms.counterpartySide)
    );
    _transfer(terms.partySide, terms.partySide.reclaimRecipient);
    _transfer(terms.counterpartySide, terms.counterpartySide.reclaimRecipient);
  }

  function _validate(ProtocolTerms memory terms, TimingPolicy memory policy, WrapperMode expected) private pure {
    ProtocolHashing.validateTerms(terms, policy);
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

  function _transfer(SideTerms memory side, address recipient) private {
    for (uint256 i; i < side.assets.length; ++i) {
      TermsLib.transferAsset(side.assets[i], address(this), recipient);
    }
  }
}
