// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {CrossChainLegState, SameChainState, SideTag} from '../../src/protocol/ProtocolTypes.sol';
import {CrossChainStateMachine, SameChainStateMachine} from '../../src/protocol/StateMachines.sol';
import {StateMachineHarness} from '../harness/StateMachineHarness.sol';

contract StateMachinesTest is Test {
  bytes32 internal constant TRADE = keccak256('trade');
  bytes32 internal constant LOCK = keccak256('lock');

  StateMachineHarness internal harness;

  function setUp() public {
    harness = new StateMachineHarness();
  }

  function test_crossChainAllowedClaimPath() public {
    _crossCommit();
    _assertCrossState(CrossChainLegState.Committed);
    harness.crossClaim(TRADE, LOCK, SideTag.Party);
    _assertCrossState(CrossChainLegState.Claimed);
  }

  function test_crossChainAllowedReclaimPath() public {
    _crossCommit();
    harness.crossReclaim(TRADE, LOCK, SideTag.Party);
    _assertCrossState(CrossChainLegState.Reclaimed);
  }

  function test_crossChainUnusedRejectsClaimAndReclaim() public {
    _expectCrossState(CrossChainLegState.Committed, CrossChainLegState.Unused);
    harness.crossClaim(TRADE, LOCK, SideTag.Party);
    _expectCrossState(CrossChainLegState.Committed, CrossChainLegState.Unused);
    harness.crossReclaim(TRADE, LOCK, SideTag.Party);
  }

  function test_crossChainCommittedRejectsSecondCommit() public {
    _crossCommit();
    _expectCrossState(CrossChainLegState.Unused, CrossChainLegState.Committed);
    harness.crossCommit(TRADE, LOCK, SideTag.Party);
  }

  function test_crossChainClaimedIsTerminal() public {
    _crossCommit();
    harness.crossClaim(TRADE, LOCK, SideTag.Party);
    _assertCrossTerminal(CrossChainLegState.Claimed);
  }

  function test_crossChainReclaimedIsTerminal() public {
    _crossCommit();
    harness.crossReclaim(TRADE, LOCK, SideTag.Party);
    _assertCrossTerminal(CrossChainLegState.Reclaimed);
  }

  function test_crossChainKeyFieldsSelectIndependentRecords() public {
    _crossCommit();
    harness.crossCommit(TRADE, LOCK, SideTag.Counterparty);
    harness.crossCommit(bytes32(uint256(TRADE) + 1), LOCK, SideTag.Party);
    harness.crossCommit(TRADE, bytes32(uint256(LOCK) + 1), SideTag.Party);
    assertEq(uint8(harness.crossState(TRADE, LOCK, SideTag.Counterparty)), uint8(CrossChainLegState.Committed));
    assertEq(
      uint8(harness.crossState(bytes32(uint256(TRADE) + 1), LOCK, SideTag.Party)), uint8(CrossChainLegState.Committed)
    );
    assertEq(
      uint8(harness.crossState(TRADE, bytes32(uint256(LOCK) + 1), SideTag.Party)), uint8(CrossChainLegState.Committed)
    );
  }

  function test_crossChainLaterFailureRollsBackTerminalTransition() public {
    _crossCommit();
    vm.expectRevert(StateMachineHarness.ForcedFailure.selector);
    harness.crossClaimThenFail(TRADE, LOCK, SideTag.Party);
    _assertCrossState(CrossChainLegState.Committed);
  }

  function test_sameChainAllowedClaimPath() public {
    _sameCommitBoth();
    _assertSameState(SameChainState.BothCommitted);
    harness.sameClaim(TRADE, LOCK);
    _assertSameState(SameChainState.Claimed);
  }

  function test_sameChainAllowedOneSidedReclaimPath() public {
    _sameCommitParty();
    harness.sameReclaimParty(TRADE, LOCK);
    _assertSameState(SameChainState.Reclaimed);
  }

  function test_sameChainAllowedDualReclaimPath() public {
    _sameCommitBoth();
    harness.sameReclaimBoth(TRADE, LOCK);
    _assertSameState(SameChainState.Reclaimed);
  }

  function test_sameChainUnusedRejectsEveryActionExceptPartyCommit() public {
    _expectSameState(SameChainState.PartyCommitted, SameChainState.Unused);
    harness.sameCommitCounterparty(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, SameChainState.Unused);
    harness.sameClaim(TRADE, LOCK);
    _expectSameState(SameChainState.PartyCommitted, SameChainState.Unused);
    harness.sameReclaimParty(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, SameChainState.Unused);
    harness.sameReclaimBoth(TRADE, LOCK);
  }

  function test_sameChainPartyCommittedRejectsAllExceptCounterCommitOrOneSidedReclaim() public {
    _sameCommitParty();
    _expectSameState(SameChainState.Unused, SameChainState.PartyCommitted);
    harness.sameCommitParty(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, SameChainState.PartyCommitted);
    harness.sameClaim(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, SameChainState.PartyCommitted);
    harness.sameReclaimBoth(TRADE, LOCK);
  }

  function test_sameChainBothCommittedRejectsAllExceptAtomicClaimOrDualReclaim() public {
    _sameCommitBoth();
    _expectSameState(SameChainState.Unused, SameChainState.BothCommitted);
    harness.sameCommitParty(TRADE, LOCK);
    _expectSameState(SameChainState.PartyCommitted, SameChainState.BothCommitted);
    harness.sameCommitCounterparty(TRADE, LOCK);
    _expectSameState(SameChainState.PartyCommitted, SameChainState.BothCommitted);
    harness.sameReclaimParty(TRADE, LOCK);
  }

  function test_sameChainClaimedIsTerminal() public {
    _sameCommitBoth();
    harness.sameClaim(TRADE, LOCK);
    _assertSameTerminal(SameChainState.Claimed);
  }

  function test_sameChainReclaimedIsTerminalFromEitherSource() public {
    _sameCommitBoth();
    harness.sameReclaimBoth(TRADE, LOCK);
    _assertSameTerminal(SameChainState.Reclaimed);
  }

  function test_sameChainTradeAndLockSelectIndependentRecords() public {
    _sameCommitParty();
    harness.sameCommitParty(bytes32(uint256(TRADE) + 1), LOCK);
    harness.sameCommitParty(TRADE, bytes32(uint256(LOCK) + 1));
    assertEq(uint8(harness.sameState(bytes32(uint256(TRADE) + 1), LOCK)), uint8(SameChainState.PartyCommitted));
    assertEq(uint8(harness.sameState(TRADE, bytes32(uint256(LOCK) + 1))), uint8(SameChainState.PartyCommitted));
  }

  function test_sameChainLaterFailureRollsBackAtomicTerminalTransition() public {
    _sameCommitBoth();
    vm.expectRevert(StateMachineHarness.ForcedFailure.selector);
    harness.sameClaimThenFail(TRADE, LOCK);
    _assertSameState(SameChainState.BothCommitted);
  }

  function _crossCommit() internal {
    harness.crossCommit(TRADE, LOCK, SideTag.Party);
  }

  function _sameCommitParty() internal {
    harness.sameCommitParty(TRADE, LOCK);
  }

  function _sameCommitBoth() internal {
    _sameCommitParty();
    harness.sameCommitCounterparty(TRADE, LOCK);
  }

  function _assertCrossState(CrossChainLegState expected) internal view {
    assertEq(uint8(harness.crossState(TRADE, LOCK, SideTag.Party)), uint8(expected));
  }

  function _assertSameState(SameChainState expected) internal view {
    assertEq(uint8(harness.sameState(TRADE, LOCK)), uint8(expected));
  }

  function _expectCrossState(CrossChainLegState expected, CrossChainLegState actual) internal {
    vm.expectRevert(abi.encodeWithSelector(CrossChainStateMachine.InvalidCrossChainState.selector, expected, actual));
  }

  function _expectSameState(SameChainState expected, SameChainState actual) internal {
    vm.expectRevert(abi.encodeWithSelector(SameChainStateMachine.InvalidSameChainState.selector, expected, actual));
  }

  function _assertCrossTerminal(CrossChainLegState terminal) internal {
    _expectCrossState(CrossChainLegState.Unused, terminal);
    harness.crossCommit(TRADE, LOCK, SideTag.Party);
    _expectCrossState(CrossChainLegState.Committed, terminal);
    harness.crossClaim(TRADE, LOCK, SideTag.Party);
    _expectCrossState(CrossChainLegState.Committed, terminal);
    harness.crossReclaim(TRADE, LOCK, SideTag.Party);
  }

  function _assertSameTerminal(SameChainState terminal) internal {
    _expectSameState(SameChainState.Unused, terminal);
    harness.sameCommitParty(TRADE, LOCK);
    _expectSameState(SameChainState.PartyCommitted, terminal);
    harness.sameCommitCounterparty(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, terminal);
    harness.sameClaim(TRADE, LOCK);
    _expectSameState(SameChainState.PartyCommitted, terminal);
    harness.sameReclaimParty(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, terminal);
    harness.sameReclaimBoth(TRADE, LOCK);
  }
}
