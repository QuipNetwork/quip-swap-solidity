// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib verifyTerms Tests
/// @dev Tests for TermsLib.verifyTerms
contract TermsLib_verifyTerms is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_verifyTerms_succeedsWithMatchingDigest() public view {
    QuipTerms memory terms = _defaultQuipTerms();
    bytes32 digest = harness.exposed_digestTerms(terms);
    harness.exposed_verifyTerms(digest, terms);
  }

  function test_verifyTerms_succeedsWithComplexTerms() public view {
    QuipTerms memory terms = TermsHelper.makeQuipTerms(
      ALICE,
      ALICE_RECIPIENT,
      BOB,
      BOB_RECIPIENT,
      DEFAULT_EXPIRY + 100,
      DEFAULT_EXPIRY + 200,
      AssetHelper.toArray(_makeNativeAsset(1 ether), _makeERC20Asset(100 ether)),
      AssetHelper.toArray(_makeERC721Asset(1), _makeERC1155Asset(1, 50))
    );

    bytes32 digest = harness.exposed_digestTerms(terms);
    harness.exposed_verifyTerms(digest, terms);
  }

  // ============ Revert Cases ============

  function test_verifyTerms_revertsWhen_digestMismatch() public {
    QuipTerms memory terms = _defaultQuipTerms();
    bytes32 wrongDigest = keccak256('wrong');

    vm.expectRevert(TermsLib.InvalidTerms.selector);
    harness.exposed_verifyTerms(wrongDigest, terms);
  }

  function test_verifyTerms_revertsWhen_partyChanged() public {
    QuipTerms memory terms = _defaultQuipTerms();
    bytes32 digest = harness.exposed_digestTerms(terms);

    terms.party = makeAddr('differentParty');

    vm.expectRevert(TermsLib.InvalidTerms.selector);
    harness.exposed_verifyTerms(digest, terms);
  }

  function test_verifyTerms_revertsWhen_counterpartyChanged() public {
    QuipTerms memory terms = _defaultQuipTerms();
    bytes32 digest = harness.exposed_digestTerms(terms);

    terms.counterparty = makeAddr('differentCounterparty');

    vm.expectRevert(TermsLib.InvalidTerms.selector);
    harness.exposed_verifyTerms(digest, terms);
  }

  function test_verifyTerms_revertsWhen_partyExpiryChanged() public {
    QuipTerms memory terms = _defaultQuipTerms();
    bytes32 digest = harness.exposed_digestTerms(terms);

    terms.partyExpiry = DEFAULT_EXPIRY + 1;

    vm.expectRevert(TermsLib.InvalidTerms.selector);
    harness.exposed_verifyTerms(digest, terms);
  }

  function test_verifyTerms_revertsWhen_assetsChanged() public {
    QuipTerms memory terms = _defaultQuipTerms();
    bytes32 digest = harness.exposed_digestTerms(terms);

    terms.partyAssets = _makeNativeAsset(2 ether).toArray();

    vm.expectRevert(TermsLib.InvalidTerms.selector);
    harness.exposed_verifyTerms(digest, terms);
  }

  function test_verifyTerms_revertsWhen_zeroDigest() public {
    QuipTerms memory terms = _defaultQuipTerms();

    vm.expectRevert(TermsLib.InvalidTerms.selector);
    harness.exposed_verifyTerms(bytes32(0), terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_verifyTerms_succeedsWithMatchingDigest(
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

    bytes32 digest = harness.exposed_digestTerms(terms);
    harness.exposed_verifyTerms(digest, terms);
  }

  function testFuzz_verifyTerms_revertsWhen_wrongDigest(bytes32 wrongDigest) public {
    QuipTerms memory terms = _defaultQuipTerms();
    bytes32 correctDigest = harness.exposed_digestTerms(terms);

    vm.assume(wrongDigest != correctDigest);

    vm.expectRevert(TermsLib.InvalidTerms.selector);
    harness.exposed_verifyTerms(wrongDigest, terms);
  }
}
