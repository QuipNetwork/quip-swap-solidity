// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {Terms} from '../../../src/TermsLib.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus _enforceSignatoryCaller Tests
/// @dev Tests for Omnibus._enforceSignatoryCaller (via harness)
contract Omnibus__enforceSignatoryCaller is OmnibusTest {
  // ============ Success Cases ============

  function test_enforceSignatoryCaller_succeedsWhenCallerIsSignatory() public {
    Terms memory terms = _aliceTerms(); // signatory ALICE
    vm.prank(ALICE);
    omnibus.exposed_enforceSignatoryCaller(terms);
  }

  // ============ Revert Cases ============

  function test_enforceSignatoryCaller_revertsWhen_callerNotSignatory() public {
    Terms memory terms = _aliceTerms(); // signatory ALICE
    vm.expectRevert(IOmnibus.CallerNotSignatory.selector);
    vm.prank(BOB);
    omnibus.exposed_enforceSignatoryCaller(terms);
  }

  function test_enforceSignatoryCaller_revertsWhen_zeroSignatory() public {
    Terms memory terms = _makeTerms(
      block.chainid,
      address(0),
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    vm.expectRevert(IOmnibus.CallerNotSignatory.selector);
    vm.prank(ALICE);
    omnibus.exposed_enforceSignatoryCaller(terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceSignatoryCaller_succeedsWhenCallerIsSignatory(address signatory) public {
    Terms memory terms = _makeTerms(
      block.chainid,
      signatory,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    vm.prank(signatory);
    omnibus.exposed_enforceSignatoryCaller(terms);
  }

  function testFuzz_enforceSignatoryCaller_revertsWhen_callerNotSignatory(address caller) public {
    vm.assume(caller != ALICE);
    Terms memory terms = _aliceTerms(); // signatory ALICE
    vm.expectRevert(IOmnibus.CallerNotSignatory.selector);
    vm.prank(caller);
    omnibus.exposed_enforceSignatoryCaller(terms);
  }
}
