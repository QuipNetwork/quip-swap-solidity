// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CrossChainStateMachine} from '../../src/CrossChainStateMachine.sol';
import {CrossChainLegState, SameChainState, SideTag} from '../../src/ProtocolTypes.sol';
import {SameChainStateMachine} from '../../src/SameChainStateMachine.sol';

contract StateMachineHarness {
  using CrossChainStateMachine for CrossChainStateMachine.Layout;
  using SameChainStateMachine for SameChainStateMachine.Layout;

  error ForcedFailure();

  CrossChainStateMachine.Layout private crossChain;
  SameChainStateMachine.Layout private sameChain;

  function crossRecord(
    bytes32 tradeId,
    bytes32 lock,
    SideTag side
  ) external view returns (CrossChainLegState state, bytes32 bindingHash) {
    CrossChainStateMachine.LegRecord memory stored = crossChain.record(tradeId, lock, side);
    return (stored.state, stored.bindingHash);
  }

  function crossCommit(bytes32 tradeId, bytes32 lock, SideTag side, bytes32 termsHash, bytes32 assetHash) external {
    crossChain.commit(tradeId, lock, side, termsHash, assetHash);
  }

  function crossClaim(bytes32 tradeId, bytes32 lock, SideTag side, bytes32 termsHash, bytes32 assetHash) external {
    crossChain.claim(tradeId, lock, side, termsHash, assetHash);
  }

  function crossReclaim(bytes32 tradeId, bytes32 lock, SideTag side, bytes32 termsHash, bytes32 assetHash) external {
    crossChain.reclaim(tradeId, lock, side, termsHash, assetHash);
  }

  function crossClaimThenFail(
    bytes32 tradeId,
    bytes32 lock,
    SideTag side,
    bytes32 termsHash,
    bytes32 assetHash
  ) external {
    crossChain.claim(tradeId, lock, side, termsHash, assetHash);
    revert ForcedFailure();
  }

  function sameRecord(bytes32 tradeId, bytes32 lock) external view returns (SameChainState state, bytes32 bindingHash) {
    SameChainStateMachine.TradeRecord memory stored = sameChain.record(tradeId, lock);
    return (stored.state, stored.bindingHash);
  }

  function sameCommitParty(
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) external {
    sameChain.commitParty(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash);
  }

  function sameCommitCounterparty(
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) external {
    sameChain.commitCounterparty(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash);
  }

  function sameClaim(
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) external {
    sameChain.claim(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash);
  }

  function sameReclaimParty(
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) external {
    sameChain.reclaimParty(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash);
  }

  function sameReclaimBoth(
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) external {
    sameChain.reclaimBoth(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash);
  }

  function sameClaimThenFail(
    bytes32 tradeId,
    bytes32 lock,
    bytes32 termsHash,
    bytes32 partyAssetHash,
    bytes32 counterpartyAssetHash
  ) external {
    sameChain.claim(tradeId, lock, termsHash, partyAssetHash, counterpartyAssetHash);
    revert ForcedFailure();
  }
}
