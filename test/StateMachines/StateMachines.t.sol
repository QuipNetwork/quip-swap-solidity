// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {CrossChainStateMachine} from '../../src/CrossChainStateMachine.sol';
import {CrossChainLegState, SameChainState, SideTag} from '../../src/ProtocolTypes.sol';
import {SameChainStateMachine} from '../../src/SameChainStateMachine.sol';
import {StateMachineHarness} from '../harness/StateMachineHarness.sol';

contract StateMachinesTest is Test {
  bytes32 internal constant TRADE = keccak256('trade');
  bytes32 internal constant LOCK = keccak256('lock');
  bytes32 internal constant TERMS = keccak256('terms');
  bytes32 internal constant PARTY_ASSETS = keccak256('party-assets');
  bytes32 internal constant COUNTERPARTY_ASSETS = keccak256('counterparty-assets');

  StateMachineHarness internal harness;

  function setUp() public {
    harness = new StateMachineHarness();
  }

  function test_crossChainAllowedClaimPathAndImmutableBinding() public {
    _crossCommit();
    (CrossChainLegState state, bytes32 binding) = harness.crossRecord(TRADE, LOCK, SideTag.Party);
    assertEq(uint8(state), uint8(CrossChainLegState.Committed));
    assertEq(binding, keccak256(abi.encode(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS)));
    harness.crossClaim(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
    _assertCrossState(CrossChainLegState.Claimed);
  }

  function test_crossChainAllowedReclaimPath() public {
    _crossCommit();
    harness.crossReclaim(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
    _assertCrossState(CrossChainLegState.Reclaimed);
  }

  function test_crossChainUnusedRejectsClaimAndReclaim() public {
    _expectCrossState(CrossChainLegState.Committed, CrossChainLegState.Unused);
    harness.crossClaim(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
    _expectCrossState(CrossChainLegState.Committed, CrossChainLegState.Unused);
    harness.crossReclaim(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
  }

  function test_crossChainCommittedRejectsSecondCommit() public {
    _crossCommit();
    _expectCrossState(CrossChainLegState.Unused, CrossChainLegState.Committed);
    harness.crossCommit(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
  }

  function test_crossChainClaimedIsTerminal() public {
    _crossCommit();
    harness.crossClaim(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
    _assertCrossTerminal(CrossChainLegState.Claimed);
  }

  function test_crossChainReclaimedIsTerminal() public {
    _crossCommit();
    harness.crossReclaim(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
    _assertCrossTerminal(CrossChainLegState.Reclaimed);
  }

  function test_crossChainRejectsEveryBindingMutationWithoutStateChange() public {
    _crossCommit();
    bytes32[5] memory changed = [
      bytes32(uint256(TRADE) ^ 1),
      bytes32(uint256(LOCK) ^ 1),
      bytes32(uint256(uint8(SideTag.Counterparty))),
      bytes32(uint256(TERMS) ^ 1),
      bytes32(uint256(PARTY_ASSETS) ^ 1)
    ];
    vm.expectRevert(CrossChainStateMachine.CrossChainBindingMismatch.selector);
    harness.crossClaim(TRADE, LOCK, SideTag.Party, changed[3], PARTY_ASSETS);
    vm.expectRevert(CrossChainStateMachine.CrossChainBindingMismatch.selector);
    harness.crossReclaim(TRADE, LOCK, SideTag.Party, TERMS, changed[4]);
    _assertCrossState(CrossChainLegState.Committed);

    // Mutating key fields addresses a different, still-Unused record.
    _expectCrossState(CrossChainLegState.Committed, CrossChainLegState.Unused);
    harness.crossClaim(changed[0], LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
    _expectCrossState(CrossChainLegState.Committed, CrossChainLegState.Unused);
    harness.crossClaim(TRADE, changed[1], SideTag.Party, TERMS, PARTY_ASSETS);
    _expectCrossState(CrossChainLegState.Committed, CrossChainLegState.Unused);
    harness.crossClaim(TRADE, LOCK, SideTag.Counterparty, TERMS, PARTY_ASSETS);
  }

  function test_crossChainSidesAndTradesAreIndependent() public {
    _crossCommit();
    harness.crossCommit(TRADE, LOCK, SideTag.Counterparty, TERMS, COUNTERPARTY_ASSETS);
    harness.crossCommit(bytes32(uint256(TRADE) + 1), LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
    (CrossChainLegState otherSide,) = harness.crossRecord(TRADE, LOCK, SideTag.Counterparty);
    (CrossChainLegState otherTrade,) = harness.crossRecord(bytes32(uint256(TRADE) + 1), LOCK, SideTag.Party);
    assertEq(uint8(otherSide), uint8(CrossChainLegState.Committed));
    assertEq(uint8(otherTrade), uint8(CrossChainLegState.Committed));
  }

  function test_crossChainLaterFailureRollsBackTerminalTransition() public {
    _crossCommit();
    vm.expectRevert(StateMachineHarness.ForcedFailure.selector);
    harness.crossClaimThenFail(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
    _assertCrossState(CrossChainLegState.Committed);
  }

  function test_sameChainAllowedClaimPathAndImmutableBinding() public {
    _sameCommitBoth();
    (SameChainState state, bytes32 binding) = harness.sameRecord(TRADE, LOCK);
    assertEq(uint8(state), uint8(SameChainState.BothCommitted));
    assertEq(binding, keccak256(abi.encode(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS)));
    harness.sameClaim(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _assertSameState(SameChainState.Claimed);
  }

  function test_sameChainAllowedOneSidedReclaimPath() public {
    _sameCommitParty();
    harness.sameReclaimParty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _assertSameState(SameChainState.Reclaimed);
  }

  function test_sameChainAllowedDualReclaimPath() public {
    _sameCommitBoth();
    harness.sameReclaimBoth(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _assertSameState(SameChainState.Reclaimed);
  }

  function test_sameChainUnusedRejectsEveryActionExceptPartyCommit() public {
    _expectSameState(SameChainState.PartyCommitted, SameChainState.Unused);
    harness.sameCommitCounterparty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _expectSameState(SameChainState.BothCommitted, SameChainState.Unused);
    harness.sameClaim(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _expectSameState(SameChainState.PartyCommitted, SameChainState.Unused);
    harness.sameReclaimParty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _expectSameState(SameChainState.BothCommitted, SameChainState.Unused);
    harness.sameReclaimBoth(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
  }

  function test_sameChainPartyCommittedRejectsAllExceptCounterCommitOrOneSidedReclaim() public {
    _sameCommitParty();
    _expectSameState(SameChainState.Unused, SameChainState.PartyCommitted);
    harness.sameCommitParty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _expectSameState(SameChainState.BothCommitted, SameChainState.PartyCommitted);
    harness.sameClaim(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _expectSameState(SameChainState.BothCommitted, SameChainState.PartyCommitted);
    harness.sameReclaimBoth(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
  }

  function test_sameChainBothCommittedRejectsAllExceptAtomicClaimOrDualReclaim() public {
    _sameCommitBoth();
    _expectSameState(SameChainState.Unused, SameChainState.BothCommitted);
    harness.sameCommitParty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _expectSameState(SameChainState.PartyCommitted, SameChainState.BothCommitted);
    harness.sameCommitCounterparty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _expectSameState(SameChainState.PartyCommitted, SameChainState.BothCommitted);
    harness.sameReclaimParty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
  }

  function test_sameChainClaimedIsTerminal() public {
    _sameCommitBoth();
    harness.sameClaim(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _assertSameTerminal(SameChainState.Claimed);
  }

  function test_sameChainReclaimedIsTerminalFromEitherSource() public {
    _sameCommitBoth();
    harness.sameReclaimBoth(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _assertSameTerminal(SameChainState.Reclaimed);
  }

  function test_sameChainRejectsBindingMutationWithoutStateChange() public {
    _sameCommitParty();
    vm.expectRevert(SameChainStateMachine.SameChainBindingMismatch.selector);
    harness.sameCommitCounterparty(TRADE, LOCK, bytes32(uint256(TERMS) ^ 1), PARTY_ASSETS, COUNTERPARTY_ASSETS);
    vm.expectRevert(SameChainStateMachine.SameChainBindingMismatch.selector);
    harness.sameReclaimParty(TRADE, LOCK, TERMS, bytes32(uint256(PARTY_ASSETS) ^ 1), COUNTERPARTY_ASSETS);
    _assertSameState(SameChainState.PartyCommitted);
  }

  function test_sameChainLaterFailureRollsBackAtomicTerminalTransition() public {
    _sameCommitBoth();
    vm.expectRevert(StateMachineHarness.ForcedFailure.selector);
    harness.sameClaimThenFail(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _assertSameState(SameChainState.BothCommitted);
  }

  function _crossCommit() internal {
    harness.crossCommit(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
  }

  function _sameCommitParty() internal {
    harness.sameCommitParty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
  }

  function _sameCommitBoth() internal {
    _sameCommitParty();
    harness.sameCommitCounterparty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
  }

  function _assertCrossState(CrossChainLegState expected) internal view {
    (CrossChainLegState actual,) = harness.crossRecord(TRADE, LOCK, SideTag.Party);
    assertEq(uint8(actual), uint8(expected));
  }

  function _assertSameState(SameChainState expected) internal view {
    (SameChainState actual,) = harness.sameRecord(TRADE, LOCK);
    assertEq(uint8(actual), uint8(expected));
  }

  function _expectCrossState(CrossChainLegState expected, CrossChainLegState actual) internal {
    vm.expectRevert(abi.encodeWithSelector(CrossChainStateMachine.InvalidCrossChainState.selector, expected, actual));
  }

  function _expectSameState(SameChainState expected, SameChainState actual) internal {
    vm.expectRevert(abi.encodeWithSelector(SameChainStateMachine.InvalidSameChainState.selector, expected, actual));
  }

  function _assertCrossTerminal(CrossChainLegState terminal) internal {
    _expectCrossState(CrossChainLegState.Unused, terminal);
    harness.crossCommit(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
    _expectCrossState(CrossChainLegState.Committed, terminal);
    harness.crossClaim(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
    _expectCrossState(CrossChainLegState.Committed, terminal);
    harness.crossReclaim(TRADE, LOCK, SideTag.Party, TERMS, PARTY_ASSETS);
  }

  function _assertSameTerminal(SameChainState terminal) internal {
    _expectSameState(SameChainState.Unused, terminal);
    harness.sameCommitParty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _expectSameState(SameChainState.PartyCommitted, terminal);
    harness.sameCommitCounterparty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _expectSameState(SameChainState.BothCommitted, terminal);
    harness.sameClaim(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _expectSameState(SameChainState.PartyCommitted, terminal);
    harness.sameReclaimParty(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
    _expectSameState(SameChainState.BothCommitted, terminal);
    harness.sameReclaimBoth(TRADE, LOCK, TERMS, PARTY_ASSETS, COUNTERPARTY_ASSETS);
  }
}
