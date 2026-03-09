// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus _enforceCurrentChain Tests
/// @dev Tests for Omnibus._enforceCurrentChain (via harness)
contract Omnibus__enforceCurrentChain is OmnibusTest {
  // ============ Success Cases ============

  function test_enforceCurrentChain_succeedsWhenMatches() public view {
    Terms memory terms = _aliceTerms();
    omnibus.exposed_enforceCurrentChain(terms);
  }

  // ============ Revert Cases ============

  function test_enforceCurrentChain_revertsWhen_differentChain() public {
    Terms memory terms = _makeTerms(
      OTHER_CHAIN_ID,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );

    vm.expectRevert(IOmnibus.ChainMismatch.selector);
    omnibus.exposed_enforceCurrentChain(terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceCurrentChain_revertsWhenDifferent(uint256 chainId) public {
    vm.assume(chainId != block.chainid);

    Terms memory terms = _makeTerms(
      chainId,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );

    vm.expectRevert(IOmnibus.ChainMismatch.selector);
    omnibus.exposed_enforceCurrentChain(terms);
  }
}
