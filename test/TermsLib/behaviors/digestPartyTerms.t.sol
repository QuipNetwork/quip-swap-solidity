// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, PartyTerms} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib digestPartyTerms Tests
/// @dev Tests for TermsLib.digestPartyTerms
contract TermsLib_digestPartyTerms is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_digestPartyTerms_returnsConsistentHash() public view {
    PartyTerms memory terms = _defaultPartyTerms();
    bytes32 digest1 = harness.exposed_digestPartyTerms(terms);
    bytes32 digest2 = harness.exposed_digestPartyTerms(terms);
    assertEq(digest1, digest2);
  }

  function test_digestPartyTerms_differentInputsProduceDifferentHashes() public view {
    PartyTerms memory baseTerms = _defaultPartyTerms();
    bytes32 baseDigest = harness.exposed_digestPartyTerms(baseTerms);

    // Different signatory
    PartyTerms memory termsSignatory = _defaultPartyTerms();
    termsSignatory.signatory = BOB;
    assertNotEq(harness.exposed_digestPartyTerms(termsSignatory), baseDigest, 'signatory should affect hash');

    // Different recipient
    PartyTerms memory termsRecipient = _defaultPartyTerms();
    termsRecipient.recipient = BOB_RECIPIENT;
    assertNotEq(harness.exposed_digestPartyTerms(termsRecipient), baseDigest, 'recipient should affect hash');

    // Different expiry
    PartyTerms memory termsExpiry = _defaultPartyTerms();
    termsExpiry.expiry = DEFAULT_EXPIRY + 1;
    assertNotEq(harness.exposed_digestPartyTerms(termsExpiry), baseDigest, 'expiry should affect hash');

    // Different assets
    PartyTerms memory termsAssets =
      TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, DEFAULT_EXPIRY, _makeNativeAsset(2 ether).toArray());
    assertNotEq(harness.exposed_digestPartyTerms(termsAssets), baseDigest, 'assets should affect hash');
  }

  function test_digestPartyTerms_matchesManualEncoding() public view {
    PartyTerms memory terms = _defaultPartyTerms();
    bytes32 expectedDigest = keccak256(abi.encode(terms.signatory, terms.recipient, terms.expiry, terms.assets));
    bytes32 actualDigest = harness.exposed_digestPartyTerms(terms);
    assertEq(actualDigest, expectedDigest);
  }

  // ============ Fuzz Tests ============

  function testFuzz_digestPartyTerms_deterministicForSameInput(
    address signatory,
    address recipient,
    uint64 expiry,
    uint256 amount
  ) public view {
    vm.assume(amount > 0);
    Asset[] memory assets = _makeNativeAsset(amount).toArray();
    PartyTerms memory terms = TermsHelper.makePartyTerms(signatory, recipient, expiry, assets);

    bytes32 digest1 = harness.exposed_digestPartyTerms(terms);
    bytes32 digest2 = harness.exposed_digestPartyTerms(terms);
    assertEq(digest1, digest2);
  }
}
