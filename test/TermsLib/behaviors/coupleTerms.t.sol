// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PartyTerms, QuipTerms} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib coupleTerms Tests
/// @dev Tests for TermsLib.coupleTerms
contract TermsLib_coupleTerms is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_coupleTerms_mergesPartyTermsCorrectly() public view {
    PartyTerms memory partyTerms = _defaultPartyTerms();
    partyTerms.expiry = DEFAULT_EXPIRY + 100;
    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, DEFAULT_EXPIRY + 200, _makeNativeAsset(2 ether).toArray());

    QuipTerms memory coupled = harness.exposed_coupleTerms(partyTerms, counterpartyTerms);

    // Verify party fields from partyTerms
    assertEq(coupled.party, partyTerms.signatory, 'party should be partyTerms.signatory');
    assertEq(coupled.partyRecipient, partyTerms.recipient, 'partyRecipient should be partyTerms.recipient');
    assertEq(coupled.partyExpiry, partyTerms.expiry, 'partyExpiry should be partyTerms.expiry');
    assertEq(coupled.partyAssets.length, partyTerms.assets.length, 'partyAssets length should match');
    assertEq(coupled.partyAssets[0].amount, partyTerms.assets[0].amount, 'partyAssets amount should match');

    // Verify counterparty fields from counterpartyTerms
    assertEq(coupled.counterparty, counterpartyTerms.signatory, 'counterparty should be counterpartyTerms.signatory');
    assertEq(
      coupled.counterpartyRecipient,
      counterpartyTerms.recipient,
      'counterpartyRecipient should be counterpartyTerms.recipient'
    );
    assertEq(
      coupled.counterpartyExpiry, counterpartyTerms.expiry, 'counterpartyExpiry should be counterpartyTerms.expiry'
    );
    assertEq(
      coupled.counterpartyAssets.length, counterpartyTerms.assets.length, 'counterpartyAssets length should match'
    );
    assertEq(
      coupled.counterpartyAssets[0].amount, counterpartyTerms.assets[0].amount, 'counterpartyAssets amount should match'
    );
  }

  // ============ Fuzz Tests ============

  function testFuzz_coupleTerms_correctlyMapsAllFields(
    address partySignatory,
    address partyRecipient,
    uint64 partyExpiry,
    address counterpartySignatory,
    address counterpartyRecipient,
    uint64 counterpartyExpiry,
    uint256 partyAmount,
    uint256 counterpartyAmount
  ) public view {
    vm.assume(partyAmount > 0);
    vm.assume(counterpartyAmount > 0);

    PartyTerms memory partyTerms =
      TermsHelper.makePartyTerms(partySignatory, partyRecipient, partyExpiry, _makeNativeAsset(partyAmount).toArray());
    PartyTerms memory counterpartyTerms = TermsHelper.makePartyTerms(
      counterpartySignatory, counterpartyRecipient, counterpartyExpiry, _makeNativeAsset(counterpartyAmount).toArray()
    );

    QuipTerms memory coupled = harness.exposed_coupleTerms(partyTerms, counterpartyTerms);

    assertEq(coupled.party, partySignatory);
    assertEq(coupled.partyRecipient, partyRecipient);
    assertEq(coupled.counterparty, counterpartySignatory);
    assertEq(coupled.counterpartyRecipient, counterpartyRecipient);
    assertEq(coupled.partyExpiry, partyExpiry);
    assertEq(coupled.counterpartyExpiry, counterpartyExpiry);
    assertEq(coupled.partyAssets[0].amount, partyAmount);
    assertEq(coupled.counterpartyAssets[0].amount, counterpartyAmount);
  }
}
