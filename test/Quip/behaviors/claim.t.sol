// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../../src/Quip.sol';
import {Asset, AssetType, QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipTest} from '../Quip.t.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title Quip claim Tests
/// @dev Tests for Quip.claim
contract Quip_claim is QuipTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_claim_transfersAllAssetTypes() public {
    // generate unique key pair for this test
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(1);

    // build party assets with all 4 asset types
    Asset[] memory partyAssets = new Asset[](4);
    partyAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 1 ether});
    partyAssets[1] = Asset({assetType: AssetType.ERC20, target: address(mockERC20), id: 0, amount: 100 ether});
    partyAssets[2] = Asset({assetType: AssetType.ERC721, target: address(mockERC721), id: ERC721_TOKEN_ID, amount: 1});
    partyAssets[3] =
      Asset({assetType: AssetType.ERC1155, target: address(mockERC1155), id: ERC1155_TOKEN_ID, amount: 50});

    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      ALICE, BOB, _defaultExpiry(), _defaultExpiry(), partyAssets, _makeNativeAssets(1 ether)
    );

    Quip quip = _deployQuipWithTerms(pqOwner, terms);

    // record balances before claim
    uint256 recipientNativeBefore = terms.counterpartyRecipient.balance;
    uint256 recipientERC20Before = mockERC20.balanceOf(terms.counterpartyRecipient);
    uint256 recipientERC1155Before = mockERC1155.balanceOf(terms.counterpartyRecipient, ERC1155_TOKEN_ID);

    // verify quip holds the assets before claim
    assertEq(address(quip).balance, 1 ether);
    assertEq(mockERC20.balanceOf(address(quip)), 100 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), address(quip));
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 50);

    // create signature for the terms
    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, terms);
    quip.claim(signature, terms);

    // verify all assets transferred to counterparty recipient
    assertEq(terms.counterpartyRecipient.balance - recipientNativeBefore, 1 ether);
    assertEq(mockERC20.balanceOf(terms.counterpartyRecipient) - recipientERC20Before, 100 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), terms.counterpartyRecipient);
    assertEq(mockERC1155.balanceOf(terms.counterpartyRecipient, ERC1155_TOKEN_ID) - recipientERC1155Before, 50);

    // verify quip is empty
    assertEq(address(quip).balance, 0);
    assertEq(mockERC20.balanceOf(address(quip)), 0);
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 0);
  }

  function test_claim_emitsPartyTermsFulfilledEvent() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.recordLogs();
    deployedQuip.claim(signature, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool found = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuip.PartyTermsFulfilled.selector) {
        found = true;
        break;
      }
    }
    assertTrue(found, 'PartyTermsFulfilled event not found');
  }

  function test_claim_isPermissionless() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // any address should be able to call claim with valid signature
    vm.prank(CHARLIE);
    deployedQuip.claim(signature, terms);

    assertEq(address(deployedQuip).balance, 0);
  }

  // ============ Revert Cases ============

  function test_claim_revertsWhen_signatureInvalid() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    // sign wrong message
    bytes32 wrongDigest = keccak256('wrong_digest');
    WOTSPlus.WinternitzElements memory wrongSignature = _signMessage(defaultPrivateKey, wrongDigest);

    vm.expectRevert(IQuip.InvalidSignature.selector);
    deployedQuip.claim(wrongSignature, terms);
  }

  function test_claim_revertsWhen_signedWithWrongKey() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    // generate different key pair and sign with it
    (, bytes32 wrongPrivateKey) = _uniqueKeyPair(999);
    WOTSPlus.WinternitzElements memory wrongSignature = _signTerms(wrongPrivateKey, terms);

    vm.expectRevert(IQuip.InvalidSignature.selector);
    deployedQuip.claim(wrongSignature, terms);
  }

  function test_claim_revertsWhen_termsInvalid() public {
    QuipTerms memory wrongTerms = _makeDefaultQuipTerms();
    wrongTerms.party = makeAddr('wrong');
    // sign the wrong terms
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, wrongTerms);

    vm.expectRevert(TermsLib.InvalidTerms.selector);
    deployedQuip.claim(signature, wrongTerms);
  }

  function test_claim_revertsWhen_termsExpired() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // warp past expiry
    vm.warp(terms.partyExpiry + 1);

    vm.expectRevert(TermsLib.TermsExpired.selector);
    deployedQuip.claim(signature, terms);
  }

  function test_claim_revertsWhen_alreadyClaimed() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // first claim succeeds
    deployedQuip.claim(signature, terms);

    // second claim fails - SafeTransferLib reverts when trying to transfer from empty balance
    vm.expectRevert(abi.encodeWithSignature('ETHTransferFailed()'));
    deployedQuip.claim(signature, terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_claim_withVariousKeyPairs(bytes32 seed) public {
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _generateKeyPair(seed);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);
    vm.assume(portal.pqOwnerState(pqOwnerHash) == PqOwnerState.Unused);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    uint256 recipientBefore = terms.counterpartyRecipient.balance;

    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, terms);
    quip.claim(signature, terms);

    uint256 expectedAmount = TermsLib.totalNativeAmount(terms.partyAssets);
    assertEq(terms.counterpartyRecipient.balance - recipientBefore, expectedAmount);
  }
}
