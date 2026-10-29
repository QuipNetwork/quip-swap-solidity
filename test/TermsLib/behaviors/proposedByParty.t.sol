// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib proposedByParty Tests
/// @dev Tests for TermsLib.proposedByParty — the proposer is the side that commits first,
///      i.e. party.commitmentDeadline < counterparty.commitmentDeadline. Only meaningful
///      after validateTermPairing has passed (which guarantees unequal commit deadlines).
contract TermsLib_proposedByParty is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Helpers ============

  function _sideWithCommitment(uint256 commitment) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      commitment,
      commitment + 100,
      commitment + 200,
      _makeNativeAsset(1 ether).toArray()
    );
  }

  // ============ Cases ============

  function test_proposedByParty_trueWhenPartyCommitsFirst() public view {
    Terms memory party = _sideWithCommitment(100);
    Terms memory counterparty = _sideWithCommitment(200);
    assertTrue(harness.exposed_proposedByParty(party, counterparty));
  }

  function test_proposedByParty_falseWhenCounterpartyCommitsFirst() public view {
    Terms memory party = _sideWithCommitment(200);
    Terms memory counterparty = _sideWithCommitment(100);
    assertFalse(harness.exposed_proposedByParty(party, counterparty));
  }

  function test_proposedByParty_isOrderDual() public view {
    // swapping the arguments flips the result for a strictly-ordered pair
    Terms memory low = _sideWithCommitment(100);
    Terms memory high = _sideWithCommitment(200);
    assertTrue(harness.exposed_proposedByParty(low, high));
    assertFalse(harness.exposed_proposedByParty(high, low));
  }

  // ============ Fuzz Tests ============

  function testFuzz_proposedByParty_tracksCommitmentOrder(uint256 partyCommit, uint256 counterCommit) public view {
    // bound below the helper's +200 headroom so deadlines never overflow
    partyCommit = bound(partyCommit, 0, type(uint256).max - 200);
    counterCommit = bound(counterCommit, 0, type(uint256).max - 200);
    // validateTermPairing guarantees these are never equal; exclude the equal case
    vm.assume(partyCommit != counterCommit);
    Terms memory party = _sideWithCommitment(partyCommit);
    Terms memory counterparty = _sideWithCommitment(counterCommit);
    assertEq(harness.exposed_proposedByParty(party, counterparty), partyCommit < counterCommit);
  }
}
