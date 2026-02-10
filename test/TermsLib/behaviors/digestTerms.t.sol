// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, QuipTerms} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib digestTerms Tests
/// @dev Tests for TermsLib.digestTerms
contract TermsLib_digestTerms is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_digestTerms_returnsConsistentHash() public view {
    QuipTerms memory terms = _defaultQuipTerms();
    bytes32 digest1 = harness.exposed_digestTerms(terms);
    bytes32 digest2 = harness.exposed_digestTerms(terms);
    assertEq(digest1, digest2);
  }

  function test_digestTerms_differentInputsProduceDifferentHashes() public {
    QuipTerms memory baseTerms = _defaultQuipTerms();
    bytes32 baseDigest = harness.exposed_digestTerms(baseTerms);

    // Different party
    QuipTerms memory termsParty = _defaultQuipTerms();
    termsParty.party = makeAddr('differentParty');
    assertNotEq(harness.exposed_digestTerms(termsParty), baseDigest, 'party should affect hash');

    // Different partyRecipient
    QuipTerms memory termsPartyRecipient = _defaultQuipTerms();
    termsPartyRecipient.partyRecipient = makeAddr('differentPartyRecipient');
    assertNotEq(harness.exposed_digestTerms(termsPartyRecipient), baseDigest, 'partyRecipient should affect hash');

    // Different counterparty
    QuipTerms memory termsCounterparty = _defaultQuipTerms();
    termsCounterparty.counterparty = makeAddr('differentCounterparty');
    assertNotEq(harness.exposed_digestTerms(termsCounterparty), baseDigest, 'counterparty should affect hash');

    // Different counterpartyRecipient
    QuipTerms memory termsCounterpartyRecipient = _defaultQuipTerms();
    termsCounterpartyRecipient.counterpartyRecipient = makeAddr('differentCounterpartyRecipient');
    assertNotEq(
      harness.exposed_digestTerms(termsCounterpartyRecipient), baseDigest, 'counterpartyRecipient should affect hash'
    );

    // Different partyExpiry
    QuipTerms memory termsPartyExpiry = _defaultQuipTerms();
    termsPartyExpiry.partyExpiry = DEFAULT_EXPIRY + 1;
    assertNotEq(harness.exposed_digestTerms(termsPartyExpiry), baseDigest, 'partyExpiry should affect hash');

    // Different counterpartyExpiry
    QuipTerms memory termsCounterpartyExpiry = _defaultQuipTerms();
    termsCounterpartyExpiry.counterpartyExpiry = DEFAULT_EXPIRY + 1;
    assertNotEq(harness.exposed_digestTerms(termsCounterpartyExpiry), baseDigest, 'counterpartyExpiry should affect hash');

    // Different partyAssets
    QuipTerms memory termsPartyAssets = _defaultQuipTerms();
    termsPartyAssets.partyAssets = _makeNativeAsset(2 ether).toArray();
    assertNotEq(harness.exposed_digestTerms(termsPartyAssets), baseDigest, 'partyAssets should affect hash');

    // Different counterpartyAssets
    QuipTerms memory termsCounterpartyAssets = _defaultQuipTerms();
    termsCounterpartyAssets.counterpartyAssets = _makeNativeAsset(2 ether).toArray();
    assertNotEq(harness.exposed_digestTerms(termsCounterpartyAssets), baseDigest, 'counterpartyAssets should affect hash');
  }

  function test_digestTerms_matchesManualEncoding() public view {
    QuipTerms memory terms = _defaultQuipTerms();
    bytes32 expectedDigest = keccak256(
      abi.encode(
        terms.party,
        terms.partyRecipient,
        terms.counterparty,
        terms.counterpartyRecipient,
        terms.partyExpiry,
        terms.counterpartyExpiry,
        terms.partyAssets,
        terms.counterpartyAssets
      )
    );
    bytes32 actualDigest = harness.exposed_digestTerms(terms);
    assertEq(actualDigest, expectedDigest);
  }

  // ============ Fuzz Tests ============

  function testFuzz_digestTerms_deterministicForSameInput(
    address party,
    address counterparty,
    uint64 partyExpiry,
    uint64 counterpartyExpiry,
    uint256 partyAmount,
    uint256 counterpartyAmount
  ) public view {
    vm.assume(partyAmount > 0);
    vm.assume(counterpartyAmount > 0);

    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      party,
      counterparty,
      partyExpiry,
      counterpartyExpiry,
      _makeNativeAsset(partyAmount).toArray(),
      _makeNativeAsset(counterpartyAmount).toArray()
    );

    bytes32 digest1 = harness.exposed_digestTerms(terms);
    bytes32 digest2 = harness.exposed_digestTerms(terms);
    assertEq(digest1, digest2);
  }
}
