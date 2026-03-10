// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Asset, AssetType, Terms, TermsLib} from '../../src/TermsLib.sol';
import {OmnibusHarness} from '../harness/OmnibusHarness.sol';
import {ERC1155Mock} from '../mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';

/// @title Omnibus Base Test
/// @dev Base contract for testing Omnibus
contract OmnibusTest is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 public constant DEFAULT_AMOUNT = 10 ether;
  uint64 public constant DEFAULT_DEADLINE_DELTA = 1 days;

  // Cross-chain simulation
  uint256 public constant OTHER_CHAIN_ID = 999;

  // Token IDs for testing
  uint256 public constant ERC721_ALICE_TOKEN = 1;
  uint256 public constant ERC721_BOB_TOKEN = 2;
  uint256 public constant ERC1155_TOKEN_ID = 1;

  // ============ Actors ============

  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public CHARLIE = makeAddr('charlie');
  address public ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  // ============ Contracts ============

  OmnibusHarness public omnibus;
  ERC20Mock public mockERC20;
  ERC721Mock public mockERC721;
  ERC1155Mock public mockERC1155;

  // ============ Test Data ============

  bytes32 public constant SECRET = keccak256('secret');
  bytes32 public lock;

  // ============ Setup ============

  function setUp() public virtual {
    // Deploy mock tokens
    mockERC20 = new ERC20Mock('MockToken', 'MTK', 18);
    mockERC721 = new ERC721Mock('MockNFT', 'MNFT');
    mockERC1155 = new ERC1155Mock('https://example.com/token/{id}.json');

    // Deploy Omnibus harness
    omnibus = new OmnibusHarness();

    // Generate lock from secret
    lock = omnibus.exposed_generateLock(SECRET);

    // Fund actors
    vm.deal(ALICE, 100 ether);
    vm.deal(BOB, 100 ether);
    vm.deal(CHARLIE, 100 ether);
    vm.deal(address(omnibus), 100 ether);

    // Mint tokens to actors
    _mintTokensTo(ALICE);
    _mintTokensTo(BOB);
    _mintTokensTo(address(omnibus));

    // Approve omnibus for all actors
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

  function _mintTokensTo(address account) internal {
    mockERC20.mint(account, 1_000_000 ether);

    // Mint specific ERC721 tokens
    mockERC721.mint(account);
    mockERC721.mint(account);
    mockERC721.mint(account);

    mockERC1155.mint(account, ERC1155_TOKEN_ID, 10000, '');
    mockERC1155.mint(account, 2, 10000, '');
  }

  function _approveAllForOmnibus(address owner) internal {
    vm.startPrank(owner);
    mockERC20.approve(address(omnibus), type(uint256).max);
    mockERC721.setApprovalForAll(address(omnibus), true);
    mockERC1155.setApprovalForAll(address(omnibus), true);
    vm.stopPrank();
  }

  function _defaultDeadline() internal view returns (uint64) {
    return uint64(block.timestamp + DEFAULT_DEADLINE_DELTA);
  }

  function _expiredDeadline() internal view returns (uint64) {
    return uint64(block.timestamp - 1);
  }

  // ============ Asset Helpers ============

  function _makeNativeAsset(uint256 amount) internal pure returns (Asset memory) {
    return AssetHelper.makeNative(amount);
  }

  function _makeNativeAssets(uint256 amount) internal pure returns (Asset[] memory) {
    return AssetHelper.makeNative(amount).toArray();
  }

  function _makeERC20Asset(uint256 amount) internal view returns (Asset memory) {
    return AssetHelper.makeERC20(address(mockERC20), amount);
  }

  function _makeERC20Assets(uint256 amount) internal view returns (Asset[] memory) {
    return AssetHelper.makeERC20(address(mockERC20), amount).toArray();
  }

  function _makeERC721Asset(uint256 tokenId) internal view returns (Asset memory) {
    return AssetHelper.makeERC721(address(mockERC721), tokenId);
  }

  function _makeERC721Assets(uint256 tokenId) internal view returns (Asset[] memory) {
    return AssetHelper.makeERC721(address(mockERC721), tokenId).toArray();
  }

  function _makeERC1155Asset(uint256 tokenId, uint256 amount) internal view returns (Asset memory) {
    return AssetHelper.makeERC1155(address(mockERC1155), tokenId, amount);
  }

  function _makeERC1155Assets(uint256 tokenId, uint256 amount) internal view returns (Asset[] memory) {
    return AssetHelper.makeERC1155(address(mockERC1155), tokenId, amount).toArray();
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
}
