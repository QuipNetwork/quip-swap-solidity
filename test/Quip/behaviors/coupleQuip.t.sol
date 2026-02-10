// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {Asset, AssetType, PartyTerms, QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {Quip} from '../../../src/Quip.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipTest} from '../Quip.t.sol';


/// @title Quip coupleQuip Tests
/// @dev Tests for Quip.coupleQuip
contract Quip_coupleQuip is QuipTest {
  using AssetHelper for *;
  using TermsHelper for *;

  Quip public uncoupledQuip;
  bytes32 public uncoupledLock;

  function setUp() public override {
    super.setUp();

    // Deploy an uncoupled quip for testing
    uncoupledLock = keccak256(abi.encodePacked('uncoupled_couple_key'));
    PartyTerms memory partyTerms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(uncoupledLock, partyTerms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    uncoupledQuip = Quip(payable(quipAddr));

    // Approve quip for asset transfers
    _approveAllForQuip(ALICE, address(uncoupledQuip));
  }

  // ============ Success Cases ============

  function test_coupleQuip_updatesTermsDigest() public {
    PartyTerms memory partyTerms = _makeDefaultPartyTerms();
    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(2 ether));

    uint256 nativeRequired = TermsLib.totalNativeAmount(partyTerms.assets);

    vm.prank(ALICE);
    uncoupledQuip.coupleQuip{value: nativeRequired}(partyTerms, counterpartyTerms);

    QuipTerms memory coupledTerms = _coupleTerms(partyTerms, counterpartyTerms);
    bytes32 expectedDigest = _digestQuipTerms(coupledTerms);
    assertEq(uncoupledQuip.termsDigest(), expectedDigest);
  }

  function test_coupleQuip_transfersAllAssetTypes() public {
    // Build party assets with all 4 asset types
    Asset[] memory partyAssets = new Asset[](4);
    partyAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 1 ether});
    partyAssets[1] = Asset({assetType: AssetType.ERC20, target: address(mockERC20), id: 0, amount: 100 ether});
    partyAssets[2] = Asset({assetType: AssetType.ERC721, target: address(mockERC721), id: ERC721_TOKEN_ID, amount: 1});
    partyAssets[3] = Asset({assetType: AssetType.ERC1155, target: address(mockERC1155), id: ERC1155_TOKEN_ID, amount: 50});

    bytes32 lock = keccak256(abi.encodePacked('all_assets_couple_key'));
    PartyTerms memory allAssetsPartyTerms = TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, _defaultExpiry(), partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(lock, allAssetsPartyTerms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip allAssetsQuip = Quip(payable(quipAddr));

    _approveAllForQuip(ALICE, address(allAssetsQuip));

    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(2 ether));

    // Record balances before coupling
    uint256 quipNativeBefore = address(allAssetsQuip).balance;
    uint256 quipERC20Before = mockERC20.balanceOf(address(allAssetsQuip));
    uint256 quipERC1155Before = mockERC1155.balanceOf(address(allAssetsQuip), ERC1155_TOKEN_ID);

    uint256 nativeRequired = TermsLib.totalNativeAmount(allAssetsPartyTerms.assets);

    vm.prank(ALICE);
    allAssetsQuip.coupleQuip{value: nativeRequired}(allAssetsPartyTerms, counterpartyTerms);

    // Verify all assets transferred to quip
    assertEq(address(allAssetsQuip).balance - quipNativeBefore, 1 ether);
    assertEq(mockERC20.balanceOf(address(allAssetsQuip)) - quipERC20Before, 100 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), address(allAssetsQuip));
    assertEq(mockERC1155.balanceOf(address(allAssetsQuip), ERC1155_TOKEN_ID) - quipERC1155Before, 50);
  }

  function test_coupleQuip_emitsQuipCommittedEvent() public {
    PartyTerms memory partyTerms = _makeDefaultPartyTerms();
    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(2 ether));

    uint256 nativeRequired = TermsLib.totalNativeAmount(partyTerms.assets);

    vm.prank(ALICE);
    vm.recordLogs();
    uncoupledQuip.coupleQuip{value: nativeRequired}(partyTerms, counterpartyTerms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool found = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuip.QuipCommitted.selector) {
        found = true;
        break;
      }
    }
    assertTrue(found, 'QuipCommitted event not found');
  }

  // ============ Revert Cases ============

  function test_coupleQuip_revertsWhen_notUncoupled() public {
    PartyTerms memory partyTerms = _makeDefaultPartyTerms();
    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(2 ether));

    // deployedQuip was initialized coupled
    vm.prank(ALICE);
    vm.expectRevert(IQuip.InvalidOperation.selector);
    deployedQuip.coupleQuip{value: 1 ether}(partyTerms, counterpartyTerms);
  }

  function test_coupleQuip_revertsWhen_partyTermsMismatch() public {
    PartyTerms memory wrongPartyTerms = TermsHelper.makePartyTerms(
      ALICE, ALICE_RECIPIENT, _defaultExpiry(), _makeNativeAssets(5 ether) // Different amount than default 1 ether
    );
    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(2 ether));

    uint256 nativeRequired = TermsLib.totalNativeAmount(wrongPartyTerms.assets);

    vm.prank(ALICE);
    vm.expectRevert(IQuip.InvalidOperation.selector);
    uncoupledQuip.coupleQuip{value: nativeRequired}(wrongPartyTerms, counterpartyTerms);
  }

  function test_coupleQuip_revertsWhen_callerNotSignatory() public {
    PartyTerms memory partyTerms = _makeDefaultPartyTerms();
    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(2 ether));

    uint256 nativeRequired = TermsLib.totalNativeAmount(partyTerms.assets);

    vm.prank(BOB); // Wrong caller
    vm.expectRevert(IQuip.UnauthorizedCaller.selector);
    uncoupledQuip.coupleQuip{value: nativeRequired}(partyTerms, counterpartyTerms);
  }

  function test_coupleQuip_revertsWhen_insufficientNative() public {
    PartyTerms memory partyTerms = _makeDefaultPartyTerms();
    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(2 ether));

    uint256 nativeRequired = TermsLib.totalNativeAmount(partyTerms.assets);

    vm.prank(ALICE);
    vm.expectRevert(IQuip.InsufficientCommitment.selector);
    uncoupledQuip.coupleQuip{value: nativeRequired - 1}(partyTerms, counterpartyTerms);
  }

  function test_coupleQuip_revertsWhen_excessNative() public {
    PartyTerms memory partyTerms = _makeDefaultPartyTerms();
    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(2 ether));

    uint256 nativeRequired = TermsLib.totalNativeAmount(partyTerms.assets);

    vm.prank(ALICE);
    vm.expectRevert(IQuip.InsufficientCommitment.selector);
    uncoupledQuip.coupleQuip{value: nativeRequired + 1}(partyTerms, counterpartyTerms);
  }
}
