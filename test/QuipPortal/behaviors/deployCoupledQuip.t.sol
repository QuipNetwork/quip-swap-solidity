// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../../src/Quip.sol';
import {Asset, AssetType, QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {IQuipPortal, PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title QuipPortal deployCoupledQuip Tests
/// @dev Tests for QuipPortal.deployCoupledQuip
contract QuipPortal_deployCoupledQuip is QuipPortalTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_deployCoupledQuip_deploysAndInitializesQuip() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify pqOwner state transitioned to Free (first deployment)
    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Free));

    // verify quip is initialized correctly
    (bytes32 publicSeed, bytes32 publicKeyHash) = quip.pqOwner();
    assertEq(publicSeed, defaultPqOwner.publicSeed);
    assertEq(publicKeyHash, defaultPqOwner.publicKeyHash);
    assertEq(quip.termsDigest(), _digestTermsCanonically(terms));
    assertFalse(quip.INIT_UNCOUPLED());
    assertEq(quip.PORTAL_FROM_BYTECODE(), address(portal));
  }

  function test_deployCoupledQuip_transitionsPqOwnerFromUnusedToFree() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Unused));

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Free));
  }

  function test_deployCoupledQuip_transitionsPqOwnerFromFreeToSpent_sameChainSwap() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // Alice deploys first quip (Unused → Free)
    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Free));

    // Bob deploys second quip with same pqOwner (Free → Spent) - enables same-chain swaps
    vm.prank(BOB);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Spent));
  }

  function test_deployCoupledQuip_accumulatesFeesAndIncreasesPortalBalance() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    uint256 feesBefore = portal.accumulatedFees();
    uint256 portalBalanceBefore = address(portal).balance;

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    assertEq(portal.accumulatedFees() - feesBefore, CREATION_FEE);
    assertEq(address(portal).balance - portalBalanceBefore, CREATION_FEE);
  }

  function test_deployCoupledQuip_transfersAllAssetTypes() public {
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

    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quip = _findQuipCreatedAddress(logs);

    // verify all assets transferred to quip
    assertEq(quip.balance, 1 ether);
    assertEq(mockERC20.balanceOf(quip), 100 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), quip);
    assertEq(mockERC1155.balanceOf(quip, ERC1155_TOKEN_ID), 50);
  }

  function test_deployCoupledQuip_emitsQuipCreatedEvent() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool found = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.QuipCreated.selector) {
        found = true;
        break;
      }
    }
    assertTrue(found, 'QuipCreated event not found');
  }

  function test_deployCoupledQuip_initializesQuipWithCorrectPqOwner() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    (bytes32 publicSeed, bytes32 publicKeyHash) = quip.pqOwner();
    assertEq(publicSeed, defaultPqOwner.publicSeed);
    assertEq(publicKeyHash, defaultPqOwner.publicKeyHash);
  }

  function test_deployCoupledQuip_initializesQuipWithCorrectTermsDigest() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    bytes32 expectedDigest = _digestTermsCanonically(terms);
    assertEq(quip.termsDigest(), expectedDigest);
  }

  // ============ Revert Cases ============

  function test_deployCoupledQuip_revertsWhen_pqOwnerPublicSeedIsZero() public {
    WOTSPlus.WinternitzAddress memory badPqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(0),
      publicKeyHash: bytes32(uint256(1))
    });
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyPqOwner.selector);
    portal.deployCoupledQuip{value: nativeRequired}(badPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_pqOwnerPublicKeyHashIsZero() public {
    WOTSPlus.WinternitzAddress memory badPqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(uint256(1)),
      publicKeyHash: bytes32(0)
    });
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyPqOwner.selector);
    portal.deployCoupledQuip{value: nativeRequired}(badPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_pqOwnerIsSpent() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // first deployment by Alice (Unused → Free)
    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    // second deployment by Bob (Free → Spent)
    vm.prank(BOB);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    // third deployment by Charlie should fail - pqOwner is fully spent
    vm.prank(CHARLIE);
    vm.expectRevert(IQuipPortal.PqOwnerSpent.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_sameDeployerUsesPqOwnerTwice() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // first deployment by Alice
    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    // second deployment by Alice with same pqOwner fails (deterministic address collision)
    vm.prank(ALICE);
    vm.expectRevert(); // LibClone.DeploymentFailed or similar
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_partyIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.party = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyParty.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_counterpartyIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterparty = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyParty.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_partyRecipientIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyRecipient = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyRecipient.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_counterpartyRecipientIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyRecipient = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyRecipient.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_partyExpiryInPast() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyExpiry = _expiredTimestamp();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_counterpartyExpiryInPast() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyExpiry = _expiredTimestamp();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_partyAssetsEmpty() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyAssets = new Asset[](0);
    uint256 nativeRequired = CREATION_FEE;

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyAssets.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_counterpartyAssetsEmpty() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyAssets = new Asset[](0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyAssets.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_incorrectNativeAmount() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portal.deployCoupledQuip{value: nativeRequired - 1}(defaultPqOwner, terms);
  }

  function test_deployCoupledQuip_revertsWhen_assetAmountZero() public {
    Asset[] memory partyAssets = _makeNativeAssets(0);
    partyAssets[0].amount = 0;
    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      ALICE, BOB, _defaultExpiry(), _defaultExpiry(), partyAssets, _makeNativeAssets(1 ether)
    );

    vm.prank(ALICE);
    vm.expectRevert(TermsLib.ZeroAmount.selector);
    portal.deployCoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_deployCoupledQuip_withVariousNativeAmounts(uint256 amount) public {
    amount = bound(amount, 1, 10 ether);

    Asset[] memory partyAssets = _makeNativeAssets(amount);
    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      ALICE, BOB, _defaultExpiry(), _defaultExpiry(), partyAssets, _makeNativeAssets(1 ether)
    );

    uint256 nativeRequired = CREATION_FEE + amount;

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quip = _findQuipCreatedAddress(logs);

    assertEq(quip.balance, amount);
  }

  function testFuzz_deployCoupledQuip_withVariousPqOwners(bytes32 seed) public {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _generateKeyPair(seed);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);
    vm.assume(portal.pqOwnerState(pqOwnerHash) == PqOwnerState.Unused);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Free));
  }
}
