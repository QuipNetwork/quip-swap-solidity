// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

import {Quip} from '../../../src/Quip.sol';
import {Asset, AssetType, QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {IQuipPortal, PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title QuipPortal deployAndClaimCoupledQuip Tests
/// @dev Tests for QuipPortal.deployAndClaimCoupledQuip
contract QuipPortal_deployAndClaimCoupledQuip is QuipPortalTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Internal Helpers ============

  /// @notice Pre-funds the predicted quip address with party assets
  /// @dev Required because deployAndClaimCoupledQuip expects quip to be pre-funded
  function _prefundQuip(
    WOTSPlus.WinternitzAddress memory pqOwner,
    address deployer,
    Asset[] memory partyAssets,
    address assetOwner
  ) internal returns (address predicted) {
    predicted = portal.predictQuipAddress(pqOwner.publicSeed, deployer);

    for (uint256 i = 0; i < partyAssets.length; i++) {
      Asset memory asset = partyAssets[i];
      if (asset.assetType == AssetType.Native) {
        vm.deal(predicted, predicted.balance + asset.amount);
      } else if (asset.assetType == AssetType.ERC20) {
        vm.prank(assetOwner);
        SafeTransferLib.safeTransfer(address(mockERC20), predicted, asset.amount);
      } else if (asset.assetType == AssetType.ERC721) {
        vm.prank(assetOwner);
        mockERC721.transferFrom(assetOwner, predicted, asset.id);
      } else if (asset.assetType == AssetType.ERC1155) {
        vm.prank(assetOwner);
        mockERC1155.safeTransferFrom(assetOwner, predicted, asset.id, asset.amount, '');
      }
    }
  }

  // ============ Success Cases ============

  function test_deployAndClaimCoupledQuip_deploysAndClaimsInSingleTx() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // Sign the terms with the default private key
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Pre-fund the predicted quip address
    _prefundQuip(defaultPqOwner, ALICE, terms.partyAssets, ALICE);

    // Record counterpartyRecipient balance before
    uint256 recipientBalanceBefore = terms.counterpartyRecipient.balance;

    vm.prank(ALICE);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    // Assert counterpartyRecipient received partyAssets (1 ether native)
    assertEq(terms.counterpartyRecipient.balance - recipientBalanceBefore, 1 ether);
  }

  function test_deployAndClaimCoupledQuip_transfersAllAssetTypes() public {
    // Build party assets with all 4 asset types
    Asset[] memory partyAssets = new Asset[](4);
    partyAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 1 ether});
    partyAssets[1] = Asset({assetType: AssetType.ERC20, target: address(mockERC20), id: 0, amount: 100 ether});
    partyAssets[2] = Asset({assetType: AssetType.ERC721, target: address(mockERC721), id: ERC721_TOKEN_ID, amount: 1});
    partyAssets[3] =
      Asset({assetType: AssetType.ERC1155, target: address(mockERC1155), id: ERC1155_TOKEN_ID, amount: 50});

    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      ALICE, BOB, _defaultExpiry(), _defaultExpiry(), partyAssets, _makeNativeAssets(1 ether)
    );

    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Pre-fund the predicted quip address
    _prefundQuip(defaultPqOwner, ALICE, partyAssets, ALICE);

    // Record balances before
    uint256 bobNativeBefore = BOB.balance;
    uint256 bobERC20Before = mockERC20.balanceOf(BOB);
    uint256 bobERC1155Before = mockERC1155.balanceOf(BOB, ERC1155_TOKEN_ID);

    vm.prank(ALICE);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    // Verify all assets transferred to counterpartyRecipient (BOB)
    assertEq(BOB.balance - bobNativeBefore, 1 ether);
    assertEq(mockERC20.balanceOf(BOB) - bobERC20Before, 100 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), BOB);
    assertEq(mockERC1155.balanceOf(BOB, ERC1155_TOKEN_ID) - bobERC1155Before, 50);
  }

  function test_deployAndClaimCoupledQuip_emitsQuipCreatedAndClaimedEvent() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Pre-fund the predicted quip address
    _prefundQuip(defaultPqOwner, ALICE, terms.partyAssets, ALICE);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool foundQuipCreatedAndClaimed = false;
    bool foundQuipCreated = false;

    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.QuipCreatedAndClaimed.selector) {
        foundQuipCreatedAndClaimed = true;
        // Verify indexed parameters
        assertEq(logs[i].topics[1], defaultPqOwnerHash);
      }
      if (logs[i].topics[0] == IQuipPortal.QuipCreated.selector) {
        foundQuipCreated = true;
      }
    }

    assertTrue(foundQuipCreatedAndClaimed, 'QuipCreatedAndClaimed event not found');
    assertFalse(foundQuipCreated, 'QuipCreated event should NOT be emitted');
  }

  function test_deployAndClaimCoupledQuip_transitionsPqOwnerToSpent() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Pre-fund the predicted quip address
    _prefundQuip(defaultPqOwner, ALICE, terms.partyAssets, ALICE);

    // pqOwner starts as Unused
    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Unused));

    vm.prank(ALICE);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    // After deployAndClaimCoupledQuip, pqOwner should be Spent (not Free)
    // Because claim() calls spendPqOwner() which transitions Free -> Spent
    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Spent));
  }

  function test_deployAndClaimCoupledQuip_accumulatesFeesCorrectly() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 partyNativeAmount = TermsLib.totalNativeAmount(terms.partyAssets);
    uint256 nativeRequired = CREATION_FEE + partyNativeAmount;
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Pre-fund the predicted quip address
    _prefundQuip(defaultPqOwner, ALICE, terms.partyAssets, ALICE);

    uint256 feesBefore = portal.accumulatedFees();
    uint256 portalBalanceBefore = address(portal).balance;

    vm.prank(ALICE);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    // accumulatedFees only increases by CREATION_FEE
    assertEq(portal.accumulatedFees() - feesBefore, CREATION_FEE);
    // Portal balance increases by full msg.value (fee + partyNative)
    // Note: The partyNative portion stays in portal since quip is pre-funded
    assertEq(address(portal).balance - portalBalanceBefore, nativeRequired);
  }

  function test_deployAndClaimCoupledQuip_worksWithMinimalAssets() public {
    // Single native asset on each side
    Asset[] memory partyAssets = _makeNativeAssets(0.1 ether);
    Asset[] memory counterpartyAssets = _makeNativeAssets(0.2 ether);

    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      ALICE, BOB, _defaultExpiry(), _defaultExpiry(), partyAssets, counterpartyAssets
    );

    uint256 nativeRequired = CREATION_FEE + 0.1 ether;
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Pre-fund the predicted quip address
    _prefundQuip(defaultPqOwner, ALICE, partyAssets, ALICE);

    uint256 bobBalanceBefore = BOB.balance;

    vm.prank(ALICE);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    assertEq(BOB.balance - bobBalanceBefore, 0.1 ether);
  }

  function test_deployAndClaimCoupledQuip_isPermissionless() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Pre-fund the predicted quip address (CHARLIE will deploy)
    _prefundQuip(defaultPqOwner, CHARLIE, terms.partyAssets, ALICE);

    uint256 bobBalanceBefore = BOB.balance;

    // CHARLIE (not party or counterparty) can call the function
    vm.prank(CHARLIE);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    // counterpartyRecipient (BOB) still receives the assets
    assertEq(BOB.balance - bobBalanceBefore, 1 ether);
  }

  function test_deployAndClaimCoupledQuip_deploysQuipWithCorrectState() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Pre-fund the predicted quip address
    _prefundQuip(defaultPqOwner, ALICE, terms.partyAssets, ALICE);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAndClaimedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Verify quip is initialized correctly
    (bytes32 publicSeed, bytes32 publicKeyHash) = quip.pqOwner();
    assertEq(publicSeed, defaultPqOwner.publicSeed);
    assertEq(publicKeyHash, defaultPqOwner.publicKeyHash);
    assertEq(quip.termsDigest(), _digestTermsCanonically(terms));
    assertFalse(quip.INIT_UNCOUPLED());
    assertEq(quip.PORTAL_FROM_BYTECODE(), address(portal));

    // Quip should have 0 balance since assets were claimed
    assertEq(quipAddr.balance, 0);
  }

  // ============ Revert Cases (from deployCoupledQuip validation) ============

  function test_deployAndClaimCoupledQuip_revertsWhen_pqOwnerPublicSeedIsZero() public {
    WOTSPlus.WinternitzAddress memory badPqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(0),
      publicKeyHash: bytes32(uint256(1))
    });
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyPqOwner.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(badPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_pqOwnerPublicKeyHashIsZero() public {
    WOTSPlus.WinternitzAddress memory badPqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(uint256(1)),
      publicKeyHash: bytes32(0)
    });
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyPqOwner.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(badPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_pqOwnerIsSpent() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Pre-fund the predicted quip address for the first call
    _prefundQuip(defaultPqOwner, ALICE, terms.partyAssets, ALICE);

    // First call deploys and claims (transitions Unused -> Free -> Spent)
    vm.prank(ALICE);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    // Second call should fail - pqOwner is spent
    vm.prank(BOB);
    vm.expectRevert(IQuipPortal.PqOwnerSpent.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_partyIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.party = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyParty.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_counterpartyIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterparty = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyParty.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_partyRecipientIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyRecipient = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyRecipient.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_counterpartyRecipientIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyRecipient = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyRecipient.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_partyExpiryInPast() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyExpiry = _expiredTimestamp();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_counterpartyExpiryInPast() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyExpiry = _expiredTimestamp();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_partyAssetsEmpty() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyAssets = new Asset[](0);
    uint256 nativeRequired = CREATION_FEE;
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyAssets.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_counterpartyAssetsEmpty() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyAssets = new Asset[](0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyAssets.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_incorrectNativeAmount() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired - 1}(defaultPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_insufficientNativeForFeeAndAssets() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    // Send only the creation fee, missing the native asset amount
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portal.deployAndClaimCoupledQuip{value: CREATION_FEE}(defaultPqOwner, signature, terms);
  }

  // ============ Revert Cases (from claim validation) ============

  function test_deployAndClaimCoupledQuip_revertsWhen_signatureInvalid() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // Create a corrupted signature
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);
    // Corrupt the first element
    signature.elements[0] = bytes32(uint256(signature.elements[0]) ^ 1);

    // Pre-fund the predicted quip address
    _prefundQuip(defaultPqOwner, ALICE, terms.partyAssets, ALICE);

    vm.prank(ALICE);
    vm.expectRevert(IQuip.InvalidSignature.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_signedWithWrongKey() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // Generate a different key pair
    (WOTSPlus.WinternitzAddress memory differentPqOwner, bytes32 differentPrivateKey) = _uniqueKeyPair(999);

    // Sign with the different private key
    WOTSPlus.WinternitzElements memory signature = _signTerms(differentPrivateKey, terms);

    // Pre-fund the predicted quip address
    _prefundQuip(defaultPqOwner, ALICE, terms.partyAssets, ALICE);

    // But deploy with the default pqOwner - signature won't match
    vm.prank(ALICE);
    vm.expectRevert(IQuip.InvalidSignature.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    // Silence unused variable warning
    differentPqOwner;
  }

  function test_deployAndClaimCoupledQuip_revertsWhen_termsModifiedAfterSigning() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // Sign the original terms
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Pre-fund the predicted quip address
    _prefundQuip(defaultPqOwner, ALICE, terms.partyAssets, ALICE);

    // Modify the terms after signing
    terms.counterpartyRecipient = CHARLIE;

    // This should revert because the modified terms don't match the signature
    vm.prank(ALICE);
    vm.expectRevert(IQuip.InvalidSignature.selector);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_deployAndClaimCoupledQuip_withVariousNativeAmounts(uint256 amount) public {
    amount = bound(amount, 1, 10 ether);

    Asset[] memory partyAssets = _makeNativeAssets(amount);
    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      ALICE, BOB, _defaultExpiry(), _defaultExpiry(), partyAssets, _makeNativeAssets(1 ether)
    );

    uint256 nativeRequired = CREATION_FEE + amount;
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Pre-fund the predicted quip address
    _prefundQuip(defaultPqOwner, ALICE, partyAssets, ALICE);

    uint256 bobBalanceBefore = BOB.balance;

    vm.prank(ALICE);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    assertEq(BOB.balance - bobBalanceBefore, amount);
  }

  function testFuzz_deployAndClaimCoupledQuip_withVariousKeyPairs(uint256 salt) public {
    salt = bound(salt, 1, type(uint256).max);

    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(salt);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, terms);

    // Pre-fund the predicted quip address
    _prefundQuip(pqOwner, ALICE, terms.partyAssets, ALICE);

    uint256 bobBalanceBefore = BOB.balance;

    vm.prank(ALICE);
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(pqOwner, signature, terms);

    // Verify pqOwner is spent
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent));
    // Verify assets transferred
    assertEq(BOB.balance - bobBalanceBefore, 1 ether);
  }

  // ============ Internal Helpers ============

  /// @notice Finds the quip address from QuipCreatedAndClaimed event in logs
  /// @dev Event signature: QuipCreatedAndClaimed(bytes32 indexed pqOwnerHash, address indexed quip, QuipTerms terms)
  function _findQuipCreatedAndClaimedAddress(Vm.Log[] memory logs) internal pure returns (address) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.QuipCreatedAndClaimed.selector) {
        // topics[1] = pqOwnerHash (indexed), topics[2] = quip address (indexed)
        return address(uint160(uint256(logs[i].topics[2])));
      }
    }
    revert('QuipCreatedAndClaimed event not found');
  }
}
