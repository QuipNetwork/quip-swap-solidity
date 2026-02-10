// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Asset, AssetType, PartyTerms, QuipTerms, TermsLib} from '../../src/TermsLib.sol';
import {TermsLibHarness} from '../harness/TermsLibHarness.sol';
import {ERC1155Mock} from '../mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';

/// @title TermsLib Base Test
/// @dev Base contract for testing TermsLib
contract TermsLibTest is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Contracts ============

  TermsLibHarness public harness;
  ERC20Mock public mockERC20;
  ERC721Mock public mockERC721;
  ERC1155Mock public mockERC1155;

  // ============ Actors ============

  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  // ============ Constants ============

  uint64 public constant DEFAULT_EXPIRY = 1_000_000;
  uint256 public constant DEFAULT_AMOUNT = 10 ether;

  // ============ Setup ============

  function setUp() public virtual {
    harness = new TermsLibHarness();

    mockERC20 = new ERC20Mock('MockToken', 'MTK', 18);
    mockERC721 = new ERC721Mock('MockNFT', 'MNFT');
    mockERC1155 = new ERC1155Mock('https://example.com/token/{id}.json');

    // Fund accounts
    vm.deal(ALICE, 100 ether);
    vm.deal(BOB, 100 ether);
    vm.deal(address(harness), 100 ether);

    // Mint tokens
    mockERC20.mint(ALICE, 1_000_000 ether);
    mockERC20.mint(BOB, 1_000_000 ether);
    mockERC20.mint(address(harness), 1_000_000 ether);

    mockERC721.mint(ALICE, 1);
    mockERC721.mint(ALICE, 2);
    mockERC721.mint(BOB, 3);
    mockERC721.mint(BOB, 4);
    mockERC721.mint(address(harness), 5);

    mockERC1155.mint(ALICE, 1, 1000, '');
    mockERC1155.mint(BOB, 2, 1000, '');
    mockERC1155.mint(address(harness), 1, 1000, '');
  }

  function test_setUp() public view {
    assertNotEq(address(harness), address(0));
    assertNotEq(address(mockERC20), address(0));
    assertNotEq(address(mockERC721), address(0));
    assertNotEq(address(mockERC1155), address(0));
  }

  // ============ Internal Helpers ============

  function _makeNativeAsset(uint256 amount) internal pure returns (Asset memory) {
    return AssetHelper.makeNative(amount);
  }

  function _makeERC20Asset(uint256 amount) internal view returns (Asset memory) {
    return AssetHelper.makeERC20(address(mockERC20), amount);
  }

  function _makeERC721Asset(uint256 tokenId) internal view returns (Asset memory) {
    return AssetHelper.makeERC721(address(mockERC721), tokenId);
  }

  function _makeERC1155Asset(uint256 tokenId, uint256 amount) internal view returns (Asset memory) {
    return AssetHelper.makeERC1155(address(mockERC1155), tokenId, amount);
  }

  function _defaultPartyTerms() internal view returns (PartyTerms memory) {
    return TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, DEFAULT_EXPIRY, _makeNativeAsset(1 ether).toArray());
  }

  function _defaultQuipTerms() internal view returns (QuipTerms memory) {
    return TermsHelper.makeQuipTerms(
      ALICE,
      ALICE_RECIPIENT,
      BOB,
      BOB_RECIPIENT,
      DEFAULT_EXPIRY,
      DEFAULT_EXPIRY,
      _makeNativeAsset(1 ether).toArray(),
      _makeNativeAsset(1 ether).toArray()
    );
  }
}
