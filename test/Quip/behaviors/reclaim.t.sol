// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {Asset, AssetType, QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {Quip} from '../../../src/Quip.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipTest} from '../Quip.t.sol';

/// @title Quip reclaim Tests
/// @dev Tests for Quip.reclaim
contract Quip_reclaim is QuipTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_reclaim_transfersAllAssetTypes() public {
    bytes memory key = abi.encodePacked('all_assets_reclaim_key');

    // Build party assets with all 4 asset types
    Asset[] memory partyAssets = new Asset[](4);
    partyAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 1 ether});
    partyAssets[1] = Asset({assetType: AssetType.ERC20, target: address(mockERC20), id: 0, amount: 100 ether});
    partyAssets[2] = Asset({assetType: AssetType.ERC721, target: address(mockERC721), id: ERC721_TOKEN_ID, amount: 1});
    partyAssets[3] = Asset({assetType: AssetType.ERC1155, target: address(mockERC1155), id: ERC1155_TOKEN_ID, amount: 50});

    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      ALICE, BOB, _defaultExpiry(), _defaultExpiry(), partyAssets, _makeNativeAssets(1 ether)
    );

    Quip quip = _deployQuipWithTerms(_computeLock(key), terms);

    // Record balances before reclaim
    uint256 recipientNativeBefore = terms.partyRecipient.balance;
    uint256 recipientERC20Before = mockERC20.balanceOf(terms.partyRecipient);
    uint256 recipientERC1155Before = mockERC1155.balanceOf(terms.partyRecipient, ERC1155_TOKEN_ID);

    // Verify quip holds the assets before reclaim
    assertEq(address(quip).balance, 1 ether);
    assertEq(mockERC20.balanceOf(address(quip)), 100 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), address(quip));
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 50);

    // Warp past expiry
    vm.warp(terms.partyExpiry);

    quip.reclaim(terms);

    // Verify all assets transferred to party recipient
    assertEq(terms.partyRecipient.balance - recipientNativeBefore, 1 ether);
    assertEq(mockERC20.balanceOf(terms.partyRecipient) - recipientERC20Before, 100 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), terms.partyRecipient);
    assertEq(mockERC1155.balanceOf(terms.partyRecipient, ERC1155_TOKEN_ID) - recipientERC1155Before, 50);

    // Verify quip is empty
    assertEq(address(quip).balance, 0);
    assertEq(mockERC20.balanceOf(address(quip)), 0);
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 0);
  }

  function test_reclaim_emitsPartyUnboundEvent() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    vm.warp(terms.partyExpiry);

    vm.recordLogs();
    deployedQuip.reclaim(terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs[0].topics[0], IQuip.PartyUnbound.selector);
  }

  function test_reclaim_isPermissionless() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    vm.warp(terms.partyExpiry);

    // Any address should be able to call reclaim after expiry
    vm.prank(CHARLIE);
    deployedQuip.reclaim(terms);

    assertEq(address(deployedQuip).balance, 0);
  }

  // ============ Revert Cases ============

  function test_reclaim_revertsWhen_termsNotExpired() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    deployedQuip.reclaim(terms);
  }

  function test_reclaim_revertsWhen_termsInvalid() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    vm.warp(terms.partyExpiry);

    QuipTerms memory wrongTerms = _makeDefaultQuipTerms();
    wrongTerms.party = makeAddr('wrong');

    vm.expectRevert(TermsLib.InvalidTerms.selector);
    deployedQuip.reclaim(wrongTerms);
  }

  function test_reclaim_revertsWhen_alreadyReclaimed() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    vm.warp(terms.partyExpiry);

    // First reclaim succeeds
    deployedQuip.reclaim(terms);

    // Second reclaim should fail (no assets to transfer)
    vm.expectRevert();
    deployedQuip.reclaim(terms);
  }

  // ============ Edge Cases ============

  function test_reclaim_succeedsAtExactExpiry() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    vm.warp(terms.partyExpiry);
    deployedQuip.reclaim(terms);
    assertEq(address(deployedQuip).balance, 0);
  }

  function test_reclaim_succeedsLongAfterExpiry() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    vm.warp(terms.partyExpiry + 365 days);
    deployedQuip.reclaim(terms);
    assertEq(address(deployedQuip).balance, 0);
  }

  // ============ Fuzz Tests ============

  function testFuzz_reclaim_afterVariousExpiryDeltas(uint256 delta) public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    delta = bound(delta, 0, 365 days);

    vm.warp(terms.partyExpiry + delta);

    uint256 recipientBefore = terms.partyRecipient.balance;

    deployedQuip.reclaim(terms);

    uint256 expectedAmount = TermsLib.totalNativeAmount(terms.partyAssets);
    assertEq(terms.partyRecipient.balance - recipientBefore, expectedAmount);
  }
}
