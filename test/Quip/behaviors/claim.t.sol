// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {Asset, AssetType, QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {Quip} from '../../../src/Quip.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipTest} from '../Quip.t.sol';

/// @title Quip claim Tests
/// @dev Tests for Quip.claim
contract Quip_claim is QuipTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_claim_transfersAllAssetTypes() public {
    bytes memory key = abi.encodePacked('all_assets_key');

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

    // Record balances before claim
    uint256 recipientNativeBefore = terms.counterpartyRecipient.balance;
    uint256 recipientERC20Before = mockERC20.balanceOf(terms.counterpartyRecipient);
    uint256 recipientERC1155Before = mockERC1155.balanceOf(terms.counterpartyRecipient, ERC1155_TOKEN_ID);

    // Verify quip holds the assets before claim
    assertEq(address(quip).balance, 1 ether);
    assertEq(mockERC20.balanceOf(address(quip)), 100 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), address(quip));
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 50);

    quip.claim(key, terms);

    // Verify all assets transferred to counterparty recipient
    assertEq(terms.counterpartyRecipient.balance - recipientNativeBefore, 1 ether);
    assertEq(mockERC20.balanceOf(terms.counterpartyRecipient) - recipientERC20Before, 100 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), terms.counterpartyRecipient);
    assertEq(mockERC1155.balanceOf(terms.counterpartyRecipient, ERC1155_TOKEN_ID) - recipientERC1155Before, 50);

    // Verify quip is empty
    assertEq(address(quip).balance, 0);
    assertEq(mockERC20.balanceOf(address(quip)), 0);
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 0);
  }

  function test_claim_emitsPartyTermsFulfilledEvent() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    vm.recordLogs();
    deployedQuip.claim(DEFAULT_KEY, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs[0].topics[0], IQuip.PartyTermsFulfilled.selector);
  }

  function test_claim_isPermissionless() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    // Any address should be able to call claim with valid key
    vm.prank(CHARLIE);
    deployedQuip.claim(DEFAULT_KEY, terms);

    assertEq(address(deployedQuip).balance, 0);
  }

  // ============ Revert Cases ============

  function test_claim_revertsWhen_keyInvalid() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    bytes memory wrongKey = 'wrong_key';

    vm.expectRevert(IQuip.InvalidKey.selector);
    deployedQuip.claim(wrongKey, terms);
  }

  function test_claim_revertsWhen_termsInvalid() public {
    QuipTerms memory wrongTerms = _makeDefaultQuipTerms();
    wrongTerms.party = makeAddr('wrong');

    vm.expectRevert(TermsLib.InvalidTerms.selector);
    deployedQuip.claim(DEFAULT_KEY, wrongTerms);
  }

  function test_claim_revertsWhen_termsExpired() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    // Warp past expiry
    vm.warp(terms.partyExpiry + 1);

    vm.expectRevert(TermsLib.TermsExpired.selector);
    deployedQuip.claim(DEFAULT_KEY, terms);
  }

  function test_claim_revertsWhen_alreadyClaimed() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    // First claim succeeds
    deployedQuip.claim(DEFAULT_KEY, terms);

    // Second claim fails - SafeTransferLib reverts when trying to transfer from empty balance
    vm.expectRevert(abi.encodeWithSignature('ETHTransferFailed()'));
    deployedQuip.claim(DEFAULT_KEY, terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_claim_withVariousKeys(bytes memory key) public {
    vm.assume(key.length > 0);
    bytes32 lock = keccak256(key);
    vm.assume(!portal.isLockSpent(lock));

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    uint256 recipientBefore = terms.counterpartyRecipient.balance;

    quip.claim(key, terms);

    uint256 expectedAmount = TermsLib.totalNativeAmount(terms.partyAssets);
    assertEq(terms.counterpartyRecipient.balance - recipientBefore, expectedAmount);
  }
}
