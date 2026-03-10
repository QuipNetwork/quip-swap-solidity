// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType, Terms, TermsLib} from '../../src/TermsLib.sol';
import {LockState} from '../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../harness/OmnibusHarness.sol';
import {TestBase} from '../utils/TestBase.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

/// @title Omnibus Base Test
/// @dev Base contract for testing Omnibus
contract OmnibusTest is TestBase {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants (Omnibus-specific) ============

  uint256 public constant OTHER_CHAIN_ID = 999;
  uint256 public constant ERC721_ALICE_TOKEN = 1;
  uint256 public constant ERC721_BOB_TOKEN = 2;
  uint256 public constant ERC1155_TOKEN_ID = 1;

  // ============ Contracts ============

  OmnibusHarness public omnibus; // Shadows TestBase.omnibus

  // ============ Test Data ============

  bytes32 public constant SECRET = keccak256('secret');
  bytes32 public lock;

  // ============ Setup ============

  function setUp() public virtual override {
    super.setUp();

    // Deploy Omnibus harness (shadows TestBase.omnibus)
    omnibus = new OmnibusHarness();

    // Generate lock from secret
    lock = omnibus.exposed_generateLock(SECRET);

    // Fund omnibus
    vm.deal(address(omnibus), 100 ether);

    // Mint tokens to omnibus
    _mintTokensTo(address(omnibus));

    // Approve omnibus for actors
    _approveAllForOmnibus(ALICE);
    _approveAllForOmnibus(BOB);
  }

  function test_setUp() public view {
    assertNotEq(address(omnibus), address(0));
    assertNotEq(address(mockERC20), address(0));
    assertNotEq(address(mockERC721), address(0));
    assertNotEq(address(mockERC1155), address(0));
    assertEq(omnibus.VERSION(), 0);
  }

  // ============ Internal Helpers ============

  /// @notice Approve omnibus harness to spend owner's tokens
  function _approveAllForOmnibus(address owner) internal {
    _approveAllFor(owner, address(omnibus));
  }

  function _expiredDeadline() internal view returns (uint64) {
    return _expiredTimestamp();
  }

  // ============ Asset Helpers (single asset variants) ============

  function _makeERC20Asset(uint256 amount) internal view returns (Asset memory) {
    return AssetHelper.makeERC20(address(mockERC20), amount);
  }

  function _makeERC721Asset(uint256 tokenId) internal view returns (Asset memory) {
    return AssetHelper.makeERC721(address(mockERC721), tokenId);
  }

  function _makeERC1155Asset(uint256 tokenId, uint256 amount) internal view returns (Asset memory) {
    return AssetHelper.makeERC1155(address(mockERC1155), tokenId, amount);
  }

  // ============ Terms Helpers ============

  /// @notice Creates default same-chain terms for Alice
  function _aliceTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
  }

  /// @notice Creates default same-chain terms for Bob
  function _bobTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      _defaultDeadline(),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );
  }

  /// @notice Creates cross-chain terms for Bob (on OTHER_CHAIN_ID)
  function _bobCrossChainTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      OTHER_CHAIN_ID,
      BOB,
      BOB_RECIPIENT,
      _defaultDeadline(),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );
  }

  /// @notice Creates terms with specific parameters
  function _makeTerms(
    uint256 chainId,
    address signatory,
    address recipient,
    uint64 deadline,
    Asset[] memory assets
  ) internal pure returns (Terms memory) {
    return TermsHelper.makeTerms(chainId, signatory, recipient, deadline, assets);
  }

  /// @notice Calculate native amount required for commit
  function _totalNativeForCommit(Terms memory terms) internal pure returns (uint256 total) {
    for (uint256 i = 0; i < terms.assets.length; i++) {
      if (terms.assets[i].assetType == AssetType.Native) {
        total += terms.assets[i].amount;
      }
    }
  }

  // ============ Commit Helpers ============

  /// @notice Helper to commit terms for a party
  function _commitFor(
    address committer,
    bytes32 _lock,
    Terms memory party,
    Terms memory counterparty
  ) internal {
    uint256 nativeAmount = _totalNativeForCommit(party);
    vm.prank(committer);
    omnibus.commit{value: nativeAmount}(_lock, party, counterparty);
  }

  /// @notice Helper to commit both parties for same-chain swaps
  function _commitBothParties(
    bytes32 _lock,
    Terms memory alice,
    Terms memory bob
  ) internal {
    _commitFor(ALICE, _lock, alice, bob);
    _commitFor(BOB, _lock, bob, alice);
  }

  // ============ Assertion Helpers ============

  /// @notice Assert lock state
  function _assertLockState(bytes32 _lock, LockState expected) internal view {
    assertEq(uint8(omnibus.lockState(_lock)), uint8(expected));
  }

  /// @notice Assert event was emitted with specific topic
  function _assertEventEmitted(
    Vm.Log[] memory logs,
    bytes32 eventSelector,
    bytes32 expectedTopic1
  ) internal pure {
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == eventSelector) {
        assertEq(logs[i].topics[1], expectedTopic1);
        return;
      }
    }
    revert("Event not found");
  }
}
