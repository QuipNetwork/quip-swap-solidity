// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetCustody} from '../assets/AssetHandling.sol';
import {ISwapHTLC} from '../interfaces/ISwapHTLC.sol';
import {ProtocolHashing} from './ProtocolHashing.sol';
import {ProtocolTerms, SideTerms, WrapperMode} from './ProtocolTypes.sol';
import {CrossChainStateMachine} from './StateMachines.sol';
import {SameChainStateMachine} from './StateMachines.sol';

/// @title Settlement
/// @notice Applies claim and reclaim predicates, advances state, and releases reserved assets.
/// @dev Claim and reclaim are permissionless; terms fix the payout recipient. State is advanced
///      before external asset transfers, and wrapper entry points additionally use a reentrancy guard.
library Settlement {
  using AssetCustody for AssetCustody.Layout;
  using CrossChainStateMachine for CrossChainStateMachine.Layout;
  using SameChainStateMachine for SameChainStateMachine.Layout;

  error InvalidSettlementMode();
  error InvalidLocalChain();
  error InvalidSettlementSecret();
  error ClaimWindowClosed();
  error ReclaimWindowClosed();
  error MissingHTLC();

  /// @notice Claims one local cross-chain leg held by its dedicated HTLC.
  function claimCrossChainHTLC(
    CrossChainStateMachine.Layout storage self,
    address htlc,
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
    if (htlc == address(0)) revert MissingHTLC();

    self.claim(trade, lock, ProtocolHashing.sideTag(party));
    ISwapHTLC(htlc).release(side, side.recipient);
  }

  /// @notice Reclaims one local cross-chain leg held by its dedicated HTLC.
  function reclaimCrossChainHTLC(
    CrossChainStateMachine.Layout storage self,
    address htlc,
    ProtocolTerms memory terms,
    bool party,
    bytes32 lock,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    _validate(terms, WrapperMode.CrossChain);
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    _requireLocal(side);
    if (timestamp < side.reclaimRelease) revert ReclaimWindowClosed();
    if (htlc == address(0)) revert MissingHTLC();

    trade = ProtocolHashing.tradeId(terms);
    self.reclaim(trade, lock, ProtocolHashing.sideTag(party));
    ISwapHTLC(htlc).release(side, side.reclaimRecipient);
  }

  /// @notice Atomically claims both same-chain legs from their dedicated HTLCs.
  function claimSameChainHTLC(
    SameChainStateMachine.Layout storage self,
    address partyHTLC,
    address counterpartyHTLC,
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
    _requireTwoHTLCs(partyHTLC, counterpartyHTLC);

    self.selectClaim(trade, lock);
    ISwapHTLC(partyHTLC).release(terms.partySide, terms.partySide.recipient);
    ISwapHTLC(counterpartyHTLC).release(terms.counterpartySide, terms.counterpartySide.recipient);
    self.completeClaim(trade, lock);
  }

  /// @notice Reclaims the sole party HTLC when no counterparty commit was recorded.
  function reclaimSameChainPartyHTLC(
    SameChainStateMachine.Layout storage self,
    address partyHTLC,
    ProtocolTerms memory terms,
    bytes32 lock,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    _validate(terms, WrapperMode.SameChain);
    _requireBothLocal(terms);
    if (timestamp < terms.partySide.reclaimRelease) revert ReclaimWindowClosed();
    if (partyHTLC == address(0)) revert MissingHTLC();

    trade = ProtocolHashing.tradeId(terms);
    self.selectReclaimParty(trade, lock);
    ISwapHTLC(partyHTLC).release(terms.partySide, terms.partySide.reclaimRecipient);
    self.completeReclaim(trade, lock);
  }

  /// @notice Atomically reclaims both committed same-chain HTLCs.
  function reclaimSameChainBothHTLC(
    SameChainStateMachine.Layout storage self,
    address partyHTLC,
    address counterpartyHTLC,
    ProtocolTerms memory terms,
    bytes32 lock,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    _validate(terms, WrapperMode.SameChain);
    _requireBothLocal(terms);
    if (timestamp < terms.partySide.reclaimRelease || timestamp < terms.counterpartySide.reclaimRelease) {
      revert ReclaimWindowClosed();
    }
    _requireTwoHTLCs(partyHTLC, counterpartyHTLC);

    trade = ProtocolHashing.tradeId(terms);
    self.selectReclaimBoth(trade, lock);
    ISwapHTLC(partyHTLC).release(terms.partySide, terms.partySide.reclaimRecipient);
    ISwapHTLC(counterpartyHTLC).release(terms.counterpartySide, terms.counterpartySide.reclaimRecipient);
    self.completeReclaim(trade, lock);
  }

  /// @notice Claims one local cross-chain leg with the trade-bound settlement preimage.
  function claimCrossChain(
    CrossChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bool party,
    bytes32 lock,
    bytes32 secret,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    // Reject same-chain terms at the cross-chain settlement entry point.
    _validate(terms, WrapperMode.CrossChain);
    // Select the local escrow leg identified by the caller.
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    _requireLocal(side);
    // Reconstruct the committed trade and verify its trade-bound HTLC preimage.
    trade = ProtocolHashing.tradeId(terms);
    _requireSecret(trade, lock, secret);
    // Claim is valid strictly before this leg claim deadline.
    if (timestamp >= side.claimDeadline) revert ClaimWindowClosed();
    // Make the terminal transition before releasing assets externally.
    self.claim(trade, lock, ProtocolHashing.sideTag(party));
    custody.release(side, side.recipient);
  }

  /// @notice Returns one local cross-chain leg after its reclaim release time.
  function reclaimCrossChain(
    CrossChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bool party,
    bytes32 lock,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    // Select and validate the locally deployed cross-chain leg.
    _validate(terms, WrapperMode.CrossChain);
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    _requireLocal(side);
    // Reclaim opens at the inclusive reclaim release time.
    if (timestamp < side.reclaimRelease) revert ReclaimWindowClosed();

    // Make the terminal transition before returning assets externally.
    trade = ProtocolHashing.tradeId(terms);
    self.reclaim(trade, lock, ProtocolHashing.sideTag(party));
    custody.release(side, side.reclaimRecipient);
  }

  /// @notice Atomically claims and releases both same-chain escrows.
  function claimSameChain(
    SameChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bytes32 lock,
    bytes32 secret,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    // Same-chain settlement requires both ordered sides to be local.
    _validate(terms, WrapperMode.SameChain);
    _requireBothLocal(terms);
    trade = ProtocolHashing.tradeId(terms);
    // A single trade-bound preimage settles both escrows.
    _requireSecret(trade, lock, secret);
    // Atomic settlement must fit inside both claim windows.
    uint256 deadline = terms.partySide.claimDeadline < terms.counterpartySide.claimDeadline
      ? terms.partySide.claimDeadline
      : terms.counterpartySide.claimDeadline;
    if (timestamp >= deadline) revert ClaimWindowClosed();

    // Select claim before either transfer; completion remains atomic in this compatibility path.
    self.selectClaim(trade, lock);
    // Release each escrow to the recipient fixed by its own side terms, then complete claim.
    custody.release(terms.partySide, terms.partySide.recipient);
    custody.release(terms.counterpartySide, terms.counterpartySide.recipient);
    self.completeClaim(trade, lock);
  }

  /// @notice Reclaims the party escrow when no counterparty commit was recorded.
  function reclaimSameChainParty(
    SameChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bytes32 lock,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    _validate(terms, WrapperMode.SameChain);
    _requireBothLocal(terms);
    // Only the first escrow exists on this state-machine branch.
    if (timestamp < terms.partySide.reclaimRelease) revert ReclaimWindowClosed();

    trade = ProtocolHashing.tradeId(terms);
    self.selectReclaimParty(trade, lock);
    custody.release(terms.partySide, terms.partySide.reclaimRecipient);
    self.completeReclaim(trade, lock);
  }

  /// @notice Atomically reclaims both committed escrows after both reclaim releases.
  function reclaimSameChainBoth(
    SameChainStateMachine.Layout storage self,
    AssetCustody.Layout storage custody,
    ProtocolTerms memory terms,
    bytes32 lock,
    uint256 timestamp
  ) internal returns (bytes32 trade) {
    _validate(terms, WrapperMode.SameChain);
    _requireBothLocal(terms);
    // Dual reclaim waits for both independently signed release times.
    if (timestamp < terms.partySide.reclaimRelease || timestamp < terms.counterpartySide.reclaimRelease) {
      revert ReclaimWindowClosed();
    }

    trade = ProtocolHashing.tradeId(terms);
    self.selectReclaimBoth(trade, lock);
    custody.release(terms.partySide, terms.partySide.reclaimRecipient);
    custody.release(terms.counterpartySide, terms.counterpartySide.reclaimRecipient);
    self.completeReclaim(trade, lock);
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

  function _requireTwoHTLCs(address partyHTLC, address counterpartyHTLC) private pure {
    if (partyHTLC == address(0) || counterpartyHTLC == address(0)) revert MissingHTLC();
  }

  function _requireSecret(bytes32 trade, bytes32 lock, bytes32 secret) private pure {
    if (ProtocolHashing.settlementLock(trade, secret) != lock) {
      revert InvalidSettlementSecret();
    }
  }
}
