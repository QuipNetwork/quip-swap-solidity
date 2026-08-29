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

  function test_sameChainAllowedClaimSelectionAndCompletion() public {
    _sameCommitBoth();
    harness.sameSelectClaim(TRADE, LOCK);
    _assertSameState(SameChainState.ClaimPending);
    _markBothSidesComplete();
    harness.sameCompleteClaim(TRADE, LOCK);
    _assertSameState(SameChainState.Claimed);
  }

  function test_sameChainAllowedOneSidedReclaimSelectionAndCompletion() public {
    _sameCommitParty();
    harness.sameSelectReclaimParty(TRADE, LOCK);
    _assertSameState(SameChainState.ReclaimPending);
    harness.sameMarkSideComplete(TRADE, LOCK, SideTag.Party);
    harness.sameCompleteReclaim(TRADE, LOCK);
    _assertSameState(SameChainState.Reclaimed);
  }

  function test_sameChainAllowedDualReclaimSelectionAndCompletion() public {
    _sameCommitBoth();
    harness.sameSelectReclaimBoth(TRADE, LOCK);
    _assertSameState(SameChainState.ReclaimPending);
    _markBothSidesComplete();
    harness.sameCompleteReclaim(TRADE, LOCK);
    _assertSameState(SameChainState.Reclaimed);
  }

  function test_sameChainUnusedRejectsEveryActionExceptPartyCommit() public {
    _expectSameState(SameChainState.PartyCommitted, SameChainState.Unused);
    harness.sameCommitCounterparty(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, SameChainState.Unused);
    harness.sameSelectClaim(TRADE, LOCK);
    _expectSameState(SameChainState.PartyCommitted, SameChainState.Unused);
    harness.sameSelectReclaimParty(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, SameChainState.Unused);
    harness.sameSelectReclaimBoth(TRADE, LOCK);
    _expectSameState(SameChainState.ClaimPending, SameChainState.Unused);
    harness.sameCompleteClaim(TRADE, LOCK);
    _expectSameState(SameChainState.ReclaimPending, SameChainState.Unused);
    harness.sameCompleteReclaim(TRADE, LOCK);
  }

  function test_sameChainPartyCommittedRejectsAllExceptCounterCommitOrOneSidedReclaim() public {
    _sameCommitParty();
    _expectSameState(SameChainState.Unused, SameChainState.PartyCommitted);
    harness.sameCommitParty(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, SameChainState.PartyCommitted);
    harness.sameSelectClaim(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, SameChainState.PartyCommitted);
    harness.sameSelectReclaimBoth(TRADE, LOCK);
    _expectSameState(SameChainState.ClaimPending, SameChainState.PartyCommitted);
    harness.sameCompleteClaim(TRADE, LOCK);
    _expectSameState(SameChainState.ReclaimPending, SameChainState.PartyCommitted);
    harness.sameCompleteReclaim(TRADE, LOCK);
  }

  function test_sameChainBothCommittedRejectsAllExceptOutcomeSelection() public {
    _sameCommitBoth();
    _expectSameState(SameChainState.Unused, SameChainState.BothCommitted);
    harness.sameCommitParty(TRADE, LOCK);
    _expectSameState(SameChainState.PartyCommitted, SameChainState.BothCommitted);
    harness.sameCommitCounterparty(TRADE, LOCK);
    _expectSameState(SameChainState.PartyCommitted, SameChainState.BothCommitted);
    harness.sameSelectReclaimParty(TRADE, LOCK);
    _expectSameState(SameChainState.ClaimPending, SameChainState.BothCommitted);
    harness.sameCompleteClaim(TRADE, LOCK);
    _expectSameState(SameChainState.ReclaimPending, SameChainState.BothCommitted);
    harness.sameCompleteReclaim(TRADE, LOCK);
  }

  function test_sameChainClaimPendingAllowsOnlyClaimCompletion() public {
    _sameCommitBoth();
    harness.sameSelectClaim(TRADE, LOCK);
    _assertPendingRejectsEveryAction(SameChainState.ClaimPending);
    _expectSameState(SameChainState.ReclaimPending, SameChainState.ClaimPending);
    harness.sameCompleteReclaim(TRADE, LOCK);
    _markBothSidesComplete();
    harness.sameCompleteClaim(TRADE, LOCK);
    _assertSameState(SameChainState.Claimed);
  }

  function test_sameChainReclaimPendingAllowsOnlyReclaimCompletion() public {
    _sameCommitBoth();
    harness.sameSelectReclaimBoth(TRADE, LOCK);
    _assertPendingRejectsEveryAction(SameChainState.ReclaimPending);
    _expectSameState(SameChainState.ClaimPending, SameChainState.ReclaimPending);
    harness.sameCompleteClaim(TRADE, LOCK);
    _markBothSidesComplete();
    harness.sameCompleteReclaim(TRADE, LOCK);
    _assertSameState(SameChainState.Reclaimed);
  }

  function test_sameChainClaimedIsTerminal() public {
    _sameCommitBoth();
    harness.sameSelectClaim(TRADE, LOCK);
    _markBothSidesComplete();
    harness.sameCompleteClaim(TRADE, LOCK);
    _assertSameTerminal(SameChainState.Claimed);
  }

  function test_sameChainReclaimedIsTerminalFromEitherSource() public {
    _sameCommitBoth();
    harness.sameSelectReclaimBoth(TRADE, LOCK);
    _markBothSidesComplete();
    harness.sameCompleteReclaim(TRADE, LOCK);
    _assertSameTerminal(SameChainState.Reclaimed);
  }

  function test_sameChainTradeAndLockSelectIndependentRecords() public {
    _sameCommitParty();
    harness.sameCommitParty(bytes32(uint256(TRADE) + 1), LOCK);
    harness.sameCommitParty(TRADE, bytes32(uint256(LOCK) + 1));
    assertEq(uint8(harness.sameState(bytes32(uint256(TRADE) + 1), LOCK)), uint8(SameChainState.PartyCommitted));
    assertEq(uint8(harness.sameState(TRADE, bytes32(uint256(LOCK) + 1))), uint8(SameChainState.PartyCommitted));
  }

  function test_sameChainLaterFailureRollsBackPendingCompletion() public {
    _sameCommitBoth();
    harness.sameSelectClaim(TRADE, LOCK);
    _markBothSidesComplete();
    vm.expectRevert(StateMachineHarness.ForcedFailure.selector);
    harness.sameCompleteClaimThenFail(TRADE, LOCK);
    _assertSameState(SameChainState.ClaimPending);
  }

  function test_sameChainSelectionStoresExactRequiredSideBitmap() public {
    _sameCommitBoth();
    harness.sameSelectClaim(TRADE, LOCK);
    _assertSameProgress(3, 0);

    bytes32 oneSidedTrade = bytes32(uint256(TRADE) + 1);
    harness.sameCommitParty(oneSidedTrade, LOCK);
    harness.sameSelectReclaimParty(oneSidedTrade, LOCK);
    (uint8 expected, uint8 completed) = harness.sameProgress(oneSidedTrade, LOCK);
    assertEq(expected, 1);
    assertEq(completed, 0);

    bytes32 dualReclaimTrade = bytes32(uint256(TRADE) + 2);
    harness.sameCommitParty(dualReclaimTrade, LOCK);
    harness.sameCommitCounterparty(dualReclaimTrade, LOCK);
    harness.sameSelectReclaimBoth(dualReclaimTrade, LOCK);
    (expected, completed) = harness.sameProgress(dualReclaimTrade, LOCK);
    assertEq(expected, 3);
    assertEq(completed, 0);
  }

  function test_sameChainCompletionBitmapSupportsEitherSideOrder() public {
    _sameCommitBoth();
    harness.sameSelectClaim(TRADE, LOCK);

    harness.sameMarkSideComplete(TRADE, LOCK, SideTag.Counterparty);
    _assertSameProgress(3, 2);
    harness.sameMarkSideComplete(TRADE, LOCK, SideTag.Party);
    _assertSameProgress(3, 3);
  }

  function test_sameChainOneSidedProgressRejectsUnexpectedAndRepeatedSides() public {
    _sameCommitParty();
    harness.sameSelectReclaimParty(TRADE, LOCK);

    vm.expectRevert(
      abi.encodeWithSelector(SameChainStateMachine.UnexpectedSettlementSide.selector, SideTag.Counterparty)
    );
    harness.sameMarkSideComplete(TRADE, LOCK, SideTag.Counterparty);
    harness.sameMarkSideComplete(TRADE, LOCK, SideTag.Party);
    vm.expectRevert(abi.encodeWithSelector(SameChainStateMachine.SettlementSideAlreadyComplete.selector, SideTag.Party));
    harness.sameMarkSideComplete(TRADE, LOCK, SideTag.Party);
    _assertSameProgress(1, 1);
  }

  function test_sameChainCannotCompleteBeforeEveryExpectedSide() public {
    _sameCommitBoth();
    harness.sameSelectClaim(TRADE, LOCK);

    vm.expectRevert(abi.encodeWithSelector(SameChainStateMachine.SettlementIncomplete.selector, 3, 0));
    harness.sameCompleteClaim(TRADE, LOCK);
    harness.sameMarkSideComplete(TRADE, LOCK, SideTag.Party);
    vm.expectRevert(abi.encodeWithSelector(SameChainStateMachine.SettlementIncomplete.selector, 3, 1));
    harness.sameCompleteClaim(TRADE, LOCK);
    harness.sameMarkSideComplete(TRADE, LOCK, SideTag.Counterparty);
    harness.sameCompleteClaim(TRADE, LOCK);
    _assertSameState(SameChainState.Claimed);
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

  function _assertSameProgress(uint8 expected, uint8 completed) internal view {
    (uint8 actualExpected, uint8 actualCompleted) = harness.sameProgress(TRADE, LOCK);
    assertEq(actualExpected, expected);
    assertEq(actualCompleted, completed);
  }

  function _markBothSidesComplete() internal {
    harness.sameMarkSideComplete(TRADE, LOCK, SideTag.Party);
    harness.sameMarkSideComplete(TRADE, LOCK, SideTag.Counterparty);
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
    harness.sameSelectClaim(TRADE, LOCK);
    _expectSameState(SameChainState.PartyCommitted, terminal);
    harness.sameSelectReclaimParty(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, terminal);
    harness.sameSelectReclaimBoth(TRADE, LOCK);
    _expectSameState(SameChainState.ClaimPending, terminal);
    harness.sameCompleteClaim(TRADE, LOCK);
    _expectSameState(SameChainState.ReclaimPending, terminal);
    harness.sameCompleteReclaim(TRADE, LOCK);
  }

  function _assertPendingRejectsEveryAction(SameChainState pending) internal {
    _expectSameState(SameChainState.Unused, pending);
    harness.sameCommitParty(TRADE, LOCK);
    _expectSameState(SameChainState.PartyCommitted, pending);
    harness.sameCommitCounterparty(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, pending);
    harness.sameSelectClaim(TRADE, LOCK);
    _expectSameState(SameChainState.PartyCommitted, pending);
    harness.sameSelectReclaimParty(TRADE, LOCK);
    _expectSameState(SameChainState.BothCommitted, pending);
    harness.sameSelectReclaimBoth(TRADE, LOCK);
  }
}
