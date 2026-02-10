// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuipPortal} from '../../../src/interfaces/IQuipPortal.sol';
import {Asset, QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal _validateQuipTerms Tests
/// @dev Tests for QuipPortal._validateQuipTerms
contract QuipPortal__validateQuipTerms is QuipPortalTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_exposed_validateQuipTerms_succeedsWithValidTerms() public view {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    portalHarness.exposed_validateQuipTerms(terms);
  }

  function test_exposed_validateQuipTerms_succeedsWithMultipleAssets() public view {
    Asset[] memory partyAssets = AssetHelper.toArray(_makeNativeAssets(1 ether)[0], _makeERC20Assets(100 ether)[0]);
    Asset[] memory counterpartyAssets = AssetHelper.toArray(_makeNativeAssets(2 ether)[0], _makeERC20Assets(50 ether)[0]);

    QuipTerms memory terms = TermsHelper.makeQuipTerms(
      ALICE, ALICE_RECIPIENT, BOB, BOB_RECIPIENT, _defaultExpiry(), _defaultExpiry(), partyAssets, counterpartyAssets
    );

    portalHarness.exposed_validateQuipTerms(terms);
  }

  // ============ Revert Cases - Party Validation ============

  function test_exposed_validateQuipTerms_revertsWhen_partyIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.party = address(0);

    vm.expectRevert(IQuipPortal.EmptyParty.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  function test_exposed_validateQuipTerms_revertsWhen_counterpartyIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterparty = address(0);

    vm.expectRevert(IQuipPortal.EmptyParty.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  // ============ Revert Cases - Recipient Validation ============

  function test_exposed_validateQuipTerms_revertsWhen_partyRecipientIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyRecipient = address(0);

    vm.expectRevert(IQuipPortal.EmptyRecipient.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  function test_exposed_validateQuipTerms_revertsWhen_counterpartyRecipientIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyRecipient = address(0);

    vm.expectRevert(IQuipPortal.EmptyRecipient.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  // ============ Revert Cases - Expiry Validation ============

  function test_exposed_validateQuipTerms_revertsWhen_partyExpiryInPast() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyExpiry = _expiredTimestamp();

    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  function test_exposed_validateQuipTerms_revertsWhen_counterpartyExpiryInPast() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyExpiry = _expiredTimestamp();

    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  function test_exposed_validateQuipTerms_revertsWhen_partyExpiryEqualsBlockTimestamp() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyExpiry = uint64(block.timestamp);

    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  function test_exposed_validateQuipTerms_revertsWhen_counterpartyExpiryEqualsBlockTimestamp() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyExpiry = uint64(block.timestamp);

    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  // ============ Revert Cases - Assets Validation ============

  function test_exposed_validateQuipTerms_revertsWhen_partyAssetsEmpty() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyAssets = new Asset[](0);

    vm.expectRevert(IQuipPortal.EmptyAssets.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  function test_exposed_validateQuipTerms_revertsWhen_counterpartyAssetsEmpty() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyAssets = new Asset[](0);

    vm.expectRevert(IQuipPortal.EmptyAssets.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  function test_exposed_validateQuipTerms_revertsWhen_partyAssetAmountZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyAssets[0].amount = 0;

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  function test_exposed_validateQuipTerms_revertsWhen_counterpartyAssetAmountZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyAssets[0].amount = 0;

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    portalHarness.exposed_validateQuipTerms(terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_exposed_validateQuipTerms_succeedsWithVariousExpiries(uint64 partyExpiry, uint64 counterpartyExpiry)
    public
    view
  {
    vm.assume(partyExpiry > block.timestamp);
    vm.assume(counterpartyExpiry > block.timestamp);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyExpiry = partyExpiry;
    terms.counterpartyExpiry = counterpartyExpiry;

    portalHarness.exposed_validateQuipTerms(terms);
  }
}
