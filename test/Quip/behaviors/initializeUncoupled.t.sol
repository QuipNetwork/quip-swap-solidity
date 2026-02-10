// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Initializable} from 'solady-0.1.26/utils/Initializable.sol';

import {Quip} from '../../../src/Quip.sol';
import {Asset, AssetType, PartyTerms} from '../../../src/TermsLib.sol';
import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipTest} from '../Quip.t.sol';

/// @title Quip initializeUncoupled Tests
/// @dev Tests for Quip.initializeUncoupled
contract Quip_initializeUncoupled is QuipTest {
  using AssetHelper for *;
  using TermsHelper for *;

  Quip public uncoupledQuip;

  function setUp() public override {
    super.setUp();

    // Deploy an uncoupled quip for testing
    bytes memory key = abi.encodePacked('uncoupled_key');
    bytes32 lock = keccak256(key);
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    uncoupledQuip = Quip(payable(quipAddr));
  }

  // ============ Success Cases ============

  function test_initializeUncoupled_setsLock() public view {
    bytes32 expectedLock = keccak256(abi.encodePacked('uncoupled_key'));
    assertEq(uncoupledQuip.lock(), expectedLock);
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
    bytes memory key = abi.encodePacked('new_uncoupled_key');
    bytes32 lock = keccak256(key);
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    // Find PartyProposal event
    bool found = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuip.PartyProposal.selector) {
        assertEq(logs[i].topics[1], lock);
        found = true;
        break;
      }
    }
    assertTrue(found, 'PartyProposal event not found');
  }

  function test_initializeUncoupled_doesNotTransferAssets() public {
    // Build party terms with all 4 asset types
    Asset[] memory assets = new Asset[](4);
    assets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 1 ether});
    assets[1] = Asset({assetType: AssetType.ERC20, target: address(mockERC20), id: 0, amount: 100 ether});
    assets[2] = Asset({assetType: AssetType.ERC721, target: address(mockERC721), id: ERC721_TOKEN_ID, amount: 1});
    assets[3] = Asset({assetType: AssetType.ERC1155, target: address(mockERC1155), id: ERC1155_TOKEN_ID, amount: 50});

    bytes32 lock = keccak256(abi.encodePacked('no_transfer_test_key'));
    PartyTerms memory terms = TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, _defaultExpiry(), assets);

    uint256 aliceERC20Before = mockERC20.balanceOf(ALICE);
    uint256 aliceERC1155Before = mockERC1155.balanceOf(ALICE, ERC1155_TOKEN_ID);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Verify no assets were transferred to the quip
    assertEq(address(quip).balance, 0);
    assertEq(mockERC20.balanceOf(address(quip)), 0);
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 0);
    // Verify Alice's balances unchanged
    assertEq(mockERC20.balanceOf(ALICE), aliceERC20Before);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), ALICE);
    assertEq(mockERC1155.balanceOf(ALICE, ERC1155_TOKEN_ID), aliceERC1155Before);
  }

  // ============ Revert Cases ============
  function test_initializeUncoupled_revertsWhen_calledDirectly() public {
    // Calling directly (not as portal) reverts with CallerNotPortal
    vm.expectRevert(IQuip.CallerNotPortal.selector);
    uncoupledQuip.initializeUncoupled(bytes32(uint256(1)), bytes32(uint256(2)));
  }

  function test_initializeUncoupled_revertsWhen_calledTwice() public {
    // Already initialized, so re-initialization fails with InvalidInitialization from Solady
    vm.prank(address(portal));
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    uncoupledQuip.initializeUncoupled(bytes32(uint256(1)), bytes32(uint256(2)));
  }

  // ============ Fuzz Tests ============

  function testFuzz_initializeUncoupled_withVariousLocks(bytes32 lock) public {
    vm.assume(lock != bytes32(0));
    vm.assume(!portal.isLockSpent(lock));

    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    assertEq(quip.lock(), lock);
    assertTrue(quip.INIT_UNCOUPLED());
  }
}
