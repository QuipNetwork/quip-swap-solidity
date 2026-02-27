// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {QuipTerms} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib digestTermsMemory Tests
/// @dev Tests for TermsLib.digestTermsMemory
contract TermsLib_digestTermsMemory is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_digestTermsMemory_returnsConsistentHash() public view {
    QuipTerms memory terms = _defaultQuipTerms();
    bytes32 digest1 = harness.exposed_digestTermsMemory(terms);
    bytes32 digest2 = harness.exposed_digestTermsMemory(terms);
    assertEq(digest1, digest2);
  }

  function test_digestTermsMemory_matchesDigestTerms() public view {
    QuipTerms memory terms = _defaultQuipTerms();
    bytes32 digestCalldata = harness.exposed_digestTerms(terms);
    bytes32 digestMemory = harness.exposed_digestTermsMemory(terms);
    assertEq(digestCalldata, digestMemory);
  }

  function test_digestTermsMemory_differentInputsProduceDifferentHashes() public {
    QuipTerms memory baseTerms = _defaultQuipTerms();
    bytes32 baseDigest = harness.exposed_digestTermsMemory(baseTerms);

    // Different party
    QuipTerms memory termsParty = _defaultQuipTerms();
    termsParty.party = makeAddr('differentParty');
    assertNotEq(harness.exposed_digestTermsMemory(termsParty), baseDigest, 'party should affect hash');

    // Different partyRecipient
    QuipTerms memory termsPartyRecipient = _defaultQuipTerms();
    termsPartyRecipient.partyRecipient = makeAddr('differentPartyRecipient');
    assertNotEq(harness.exposed_digestTermsMemory(termsPartyRecipient), baseDigest, 'partyRecipient should affect hash');

    // Different counterparty
    QuipTerms memory termsCounterparty = _defaultQuipTerms();
    termsCounterparty.counterparty = makeAddr('differentCounterparty');
    assertNotEq(harness.exposed_digestTermsMemory(termsCounterparty), baseDigest, 'counterparty should affect hash');

    // Different counterpartyRecipient
    QuipTerms memory termsCounterpartyRecipient = _defaultQuipTerms();
    termsCounterpartyRecipient.counterpartyRecipient = makeAddr('differentCounterpartyRecipient');
    assertNotEq(
      harness.exposed_digestTermsMemory(termsCounterpartyRecipient),
      baseDigest,
      'counterpartyRecipient should affect hash'
    );

    // Different partyExpiry
    QuipTerms memory termsPartyExpiry = _defaultQuipTerms();
    termsPartyExpiry.partyExpiry = DEFAULT_EXPIRY + 1;
    assertNotEq(harness.exposed_digestTermsMemory(termsPartyExpiry), baseDigest, 'partyExpiry should affect hash');

    // Different counterpartyExpiry
    QuipTerms memory termsCounterpartyExpiry = _defaultQuipTerms();
    termsCounterpartyExpiry.counterpartyExpiry = DEFAULT_EXPIRY + 1;
    assertNotEq(
      harness.exposed_digestTermsMemory(termsCounterpartyExpiry), baseDigest, 'counterpartyExpiry should affect hash'
    );

    // Different partyAssets
    QuipTerms memory termsPartyAssets = _defaultQuipTerms();
    termsPartyAssets.partyAssets = _makeNativeAsset(2 ether).toArray();
    assertNotEq(harness.exposed_digestTermsMemory(termsPartyAssets), baseDigest, 'partyAssets should affect hash');

    // Different counterpartyAssets
    QuipTerms memory termsCounterpartyAssets = _defaultQuipTerms();
    termsCounterpartyAssets.counterpartyAssets = _makeNativeAsset(2 ether).toArray();
    assertNotEq(
      harness.exposed_digestTermsMemory(termsCounterpartyAssets), baseDigest, 'counterpartyAssets should affect hash'
    );
  }

  // ============ Fuzz Tests ============

  function testFuzz_digestTermsMemory_matchesDigestTerms(
    address party,
    address counterparty,
    uint64 partyExpiry,
    uint64 counterpartyExpiry,
    uint256 amount
  ) public view {
    vm.assume(amount > 0);

    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      party,
      counterparty,
      partyExpiry,
      counterpartyExpiry,
      _makeNativeAsset(amount).toArray(),
      _makeNativeAsset(amount).toArray()
    );

    bytes32 digestCalldata = harness.exposed_digestTerms(terms);
    bytes32 digestMemory = harness.exposed_digestTermsMemory(terms);
    assertEq(digestCalldata, digestMemory);
  }
}
