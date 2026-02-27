// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Initializable} from 'solady-0.1.26/utils/Initializable.sol';

import {Quip} from '../../../src/Quip.sol';
import {Asset, AssetType, PartyTerms} from '../../../src/TermsLib.sol';
import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipTest} from '../Quip.t.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title Quip initializeUncoupled Tests
/// @dev Tests for Quip.initializeUncoupled
contract Quip_initializeUncoupled is QuipTest {
  using AssetHelper for *;
  using TermsHelper for *;

  Quip public uncoupledQuip;
  WOTSPlus.WinternitzAddress public uncoupledPqOwner;

  function setUp() public override {
    super.setUp();

    // Deploy an uncoupled quip for testing
    (uncoupledPqOwner,) = _uniqueKeyPair(100);
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(uncoupledPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    uncoupledQuip = Quip(payable(quipAddr));
  }

  // ============ Success Cases ============

  function test_initializeUncoupled_setsPqOwner() public view {
    (bytes32 publicSeed, bytes32 publicKeyHash) = uncoupledQuip.pqOwner();
    assertEq(publicSeed, uncoupledPqOwner.publicSeed);
    assertEq(publicKeyHash, uncoupledPqOwner.publicKeyHash);
  }

  function test_initializeUncoupled_setsTermsDigest() public view {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    bytes32 expectedDigest = _digestPartyTerms(terms);
    assertEq(uncoupledQuip.termsDigest(), expectedDigest);
  }

  function test_initializeUncoupled_setsInitUncoupledTrue() public view {
    assertTrue(uncoupledQuip.INIT_UNCOUPLED());
  }

  function test_initializeUncoupled_emitsPartyProposalEvent() public {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _uniqueKeyPair(101);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    // find PartyProposal event
    bool found = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuip.PartyProposal.selector) {
        assertEq(logs[i].topics[1], pqOwnerHash);
        found = true;
        break;
      }
    }
    assertTrue(found, 'PartyProposal event not found');
  }

  function test_initializeUncoupled_doesNotTransferAssets() public {
    // build party terms with all 4 asset types
    Asset[] memory assets = new Asset[](4);
    assets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 1 ether});
    assets[1] = Asset({assetType: AssetType.ERC20, target: address(mockERC20), id: 0, amount: 100 ether});
    assets[2] = Asset({assetType: AssetType.ERC721, target: address(mockERC721), id: ERC721_TOKEN_ID, amount: 1});
    assets[3] = Asset({assetType: AssetType.ERC1155, target: address(mockERC1155), id: ERC1155_TOKEN_ID, amount: 50});

    (WOTSPlus.WinternitzAddress memory pqOwner,) = _uniqueKeyPair(102);
    PartyTerms memory terms = TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, _defaultExpiry(), assets);

    uint256 aliceERC20Before = mockERC20.balanceOf(ALICE);
    uint256 aliceERC1155Before = mockERC1155.balanceOf(ALICE, ERC1155_TOKEN_ID);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify no assets were transferred to the quip
    assertEq(address(quip).balance, 0);
    assertEq(mockERC20.balanceOf(address(quip)), 0);
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 0);
    // verify Alice's balances unchanged
    assertEq(mockERC20.balanceOf(ALICE), aliceERC20Before);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), ALICE);
    assertEq(mockERC1155.balanceOf(ALICE, ERC1155_TOKEN_ID), aliceERC1155Before);
  }

  // ============ Revert Cases ============
  function test_initializeUncoupled_revertsWhen_calledDirectly() public {
    WOTSPlus.WinternitzAddress memory pqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(uint256(1)),
      publicKeyHash: bytes32(uint256(2))
    });
    // calling directly (not as portal) reverts with CallerNotPortal
    vm.expectRevert(IQuip.CallerNotPortal.selector);
    uncoupledQuip.initializeUncoupled(pqOwner, bytes32(uint256(3)));
  }

  function test_initializeUncoupled_revertsWhen_calledTwice() public {
    WOTSPlus.WinternitzAddress memory pqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(uint256(1)),
      publicKeyHash: bytes32(uint256(2))
    });
    // already initialized, so re-initialization fails with InvalidInitialization from Solady
    vm.prank(address(portal));
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    uncoupledQuip.initializeUncoupled(pqOwner, bytes32(uint256(3)));
  }

  // ============ Fuzz Tests ============

  function testFuzz_initializeUncoupled_withVariousPqOwners(bytes32 seed) public {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _generateKeyPair(seed);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);
    vm.assume(portal.pqOwnerState(pqOwnerHash) == PqOwnerState.Unused);

    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    (bytes32 publicSeed, bytes32 publicKeyHash) = quip.pqOwner();
    assertEq(publicSeed, pqOwner.publicSeed);
    assertEq(publicKeyHash, pqOwner.publicKeyHash);
    assertTrue(quip.INIT_UNCOUPLED());
  }
}
