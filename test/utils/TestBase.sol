// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Asset} from '../../src/protocol/ProtocolTypes.sol';

import {ERC1155Mock} from '../mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';
import {AssetHelper} from './AssetHelper.sol';
import {TermsHelper} from './TermsHelper.sol';

/// @title Test Base
/// @dev Base contract for all tests with shared setup, actors, and constants
abstract contract TestBase is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 public constant DEFAULT_AMOUNT = 10 ether;
  uint64 public constant DEFAULT_DEADLINE_DELTA = 1 days;

  // ============ Actors ============

  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public CHARLIE = makeAddr('charlie');
  address public ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  // ============ Contracts ============

  ERC20Mock public mockERC20;
  ERC721Mock public mockERC721;
  ERC1155Mock public mockERC1155;

  // ============ Setup ============

  function setUp() public virtual {
    // deploy mock tokens
    mockERC20 = new ERC20Mock('MockToken', 'MTK', 18);
    mockERC721 = new ERC721Mock('MockNFT', 'MNFT');
    mockERC1155 = new ERC1155Mock('https://example.com/token/{id}.json');

    // fund actors
    vm.deal(ALICE, 100 ether);
    vm.deal(BOB, 100 ether);
    vm.deal(CHARLIE, 100 ether);

    // mint tokens to actors
    _mintTokensTo(ALICE);
    _mintTokensTo(BOB);
    _mintTokensTo(CHARLIE);
  }

  // ============ Internal Helpers ============

  function _mintTokensTo(address account) internal {
    mockERC20.mint(account, 1_000_000 ether);
    mockERC721.mint(account);
    mockERC721.mint(account);
    mockERC721.mint(account);
    mockERC1155.mint(account, 1, 1000, '');
    mockERC1155.mint(account, 2, 1000, '');
  }

  function _defaultDeadline() internal view returns (uint64) {
    return uint64(block.timestamp + DEFAULT_DEADLINE_DELTA);
  }

  function _expiredTimestamp() internal view returns (uint64) {
    return uint64(block.timestamp - 1);
  }

  function _approveAllFor(address owner, address spender) internal {
    vm.startPrank(owner);
    mockERC20.approve(spender, type(uint256).max);
    mockERC721.setApprovalForAll(spender, true);
    mockERC1155.setApprovalForAll(spender, true);
    vm.stopPrank();
  }

  function _makeNativeAsset(uint256 amount) internal pure returns (Asset memory) {
    return AssetHelper.makeNative(amount);
  }

  function _makeNativeAssets(uint256 amount) internal pure returns (Asset[] memory) {
    return AssetHelper.makeNative(amount).toArray();
  }

  function _makeERC20Assets(uint256 amount) internal view returns (Asset[] memory) {
    return AssetHelper.makeERC20(address(mockERC20), amount).toArray();
  }

  function _makeERC721Assets(uint256 tokenId) internal view returns (Asset[] memory) {
    return AssetHelper.makeERC721(address(mockERC721), tokenId).toArray();
  }

  function _makeERC1155Assets(uint256 tokenId, uint256 amount) internal view returns (Asset[] memory) {
    return AssetHelper.makeERC1155(address(mockERC1155), tokenId, amount).toArray();
  }
}
