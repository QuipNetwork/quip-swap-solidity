// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CrossChainLegState, SameChainState, SideTag} from '../../src/protocol/ProtocolTypes.sol';
import {CrossChainStateMachine, SameChainStateMachine} from '../../src/protocol/StateMachines.sol';

contract StateMachineHarness {
  using CrossChainStateMachine for CrossChainStateMachine.Layout;
  using SameChainStateMachine for SameChainStateMachine.Layout;

  error ForcedFailure();

  CrossChainStateMachine.Layout private crossChain;
  SameChainStateMachine.Layout private sameChain;

  function crossState(bytes32 tradeId, bytes32 lock, SideTag side) external view returns (CrossChainLegState) {
    return crossChain.state(tradeId, lock, side);
  }

  function crossCommit(bytes32 tradeId, bytes32 lock, SideTag side) external {
    crossChain.commit(tradeId, lock, side);
  }

  function crossClaim(bytes32 tradeId, bytes32 lock, SideTag side) external {
    crossChain.claim(tradeId, lock, side);
  }

  function crossReclaim(bytes32 tradeId, bytes32 lock, SideTag side) external {
    crossChain.reclaim(tradeId, lock, side);
  }

  function crossClaimThenFail(bytes32 tradeId, bytes32 lock, SideTag side) external {
    crossChain.claim(tradeId, lock, side);
    revert ForcedFailure();
  }

  function sameState(bytes32 tradeId, bytes32 lock) external view returns (SameChainState) {
    return sameChain.state(tradeId, lock);
  }

  function sameCommitParty(bytes32 tradeId, bytes32 lock) external {
    sameChain.commitParty(tradeId, lock);
  }

  function sameCommitCounterparty(bytes32 tradeId, bytes32 lock) external {
    sameChain.commitCounterparty(tradeId, lock);
  }

  function sameSelectClaim(bytes32 tradeId, bytes32 lock) external {
    sameChain.selectClaim(tradeId, lock);
  }

  function sameSelectReclaimParty(bytes32 tradeId, bytes32 lock) external {
    sameChain.selectReclaimParty(tradeId, lock);
  }

  function sameSelectReclaimBoth(bytes32 tradeId, bytes32 lock) external {
    sameChain.selectReclaimBoth(tradeId, lock);
  }

  function sameCompleteClaim(bytes32 tradeId, bytes32 lock) external {
    sameChain.completeClaim(tradeId, lock);
  }

  function sameCompleteReclaim(bytes32 tradeId, bytes32 lock) external {
    sameChain.completeReclaim(tradeId, lock);
  }

  function sameCompleteClaimThenFail(bytes32 tradeId, bytes32 lock) external {
    sameChain.completeClaim(tradeId, lock);
    revert ForcedFailure();
  }
}
