// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, PartyTerms, TermsLib} from '../../../src/TermsLib.sol';
import {IQuipPortal} from '../../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal _validatePartyTerms Tests
/// @dev Tests for QuipPortal._validatePartyTerms
contract QuipPortal__validatePartyTerms is QuipPortalTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_exposed_validatePartyTerms_succeedsWithValidTerms() public view {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    portalHarness.exposed_validatePartyTerms(terms);
  }

  function test_exposed_validatePartyTerms_succeedsWithMultipleAssets() public view {
    Asset[] memory assets = AssetHelper.toArray(_makeNativeAssets(1 ether)[0], _makeERC20Assets(100 ether)[0]);

    PartyTerms memory terms = TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, _defaultExpiry(), assets);

    portalHarness.exposed_validatePartyTerms(terms);
  }

  // ============ Revert Cases - Signatory Validation ============

  function test_exposed_validatePartyTerms_revertsWhen_signatoryIsZero() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.signatory = address(0);

    vm.expectRevert(IQuipPortal.EmptyParty.selector);
    portalHarness.exposed_validatePartyTerms(terms);
  }

  // ============ Revert Cases - Recipient Validation ============

  function test_exposed_validatePartyTerms_revertsWhen_recipientIsZero() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.recipient = address(0);

    vm.expectRevert(IQuipPortal.EmptyRecipient.selector);
    portalHarness.exposed_validatePartyTerms(terms);
  }

  // ============ Revert Cases - Expiry Validation ============

  function test_exposed_validatePartyTerms_revertsWhen_expiryInPast() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.expiry = _expiredTimestamp();

    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portalHarness.exposed_validatePartyTerms(terms);
  }

  function test_exposed_validatePartyTerms_revertsWhen_expiryEqualsBlockTimestamp() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.expiry = uint64(block.timestamp);

    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portalHarness.exposed_validatePartyTerms(terms);
  }

  // ============ Revert Cases - Assets Validation ============

  function test_exposed_validatePartyTerms_revertsWhen_assetsEmpty() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.assets = new Asset[](0);

    vm.expectRevert(IQuipPortal.EmptyAssets.selector);
    portalHarness.exposed_validatePartyTerms(terms);
  }

  function test_exposed_validatePartyTerms_revertsWhen_assetAmountZero() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.assets[0].amount = 0;

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    portalHarness.exposed_validatePartyTerms(terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_exposed_validatePartyTerms_succeedsWithVariousExpiries(uint64 expiry) public view {
    vm.assume(expiry > block.timestamp);

    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.expiry = expiry;

    portalHarness.exposed_validatePartyTerms(terms);
  }

  function testFuzz_exposed_validatePartyTerms_succeedsWithVariousSignatories(address signatory) public view {
    vm.assume(signatory != address(0));

    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.signatory = signatory;

    portalHarness.exposed_validatePartyTerms(terms);
  }

  function testFuzz_exposed_validatePartyTerms_succeedsWithVariousRecipients(address recipient) public view {
    vm.assume(recipient != address(0));

    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.recipient = recipient;

    portalHarness.exposed_validatePartyTerms(terms);
  }
}
