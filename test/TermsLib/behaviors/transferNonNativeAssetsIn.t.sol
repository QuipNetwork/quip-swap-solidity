// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, Terms} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';

/// @title TermsLib transferNonNativeAssetsIn Tests
/// @dev Tests for TermsLib.transferNonNativeAssetsIn
contract TermsLib_transferNonNativeAssetsIn is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Setup ============

  function setUp() public override {
    super.setUp();

    // Approve harness for ALICE
    vm.startPrank(ALICE);
    mockERC20.approve(address(harness), type(uint256).max);
    mockERC721.setApprovalForAll(address(harness), true);
    mockERC1155.setApprovalForAll(address(harness), true);
    vm.stopPrank();
  }

  // ============ Success Cases ============

  function test_transferNonNativeAssetsIn_skipsNativeCollateral() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeNativeAsset(1 ether), // Native collateral - should be skipped
      _makeERC20Asset(100 ether).toArray()
    );

    uint256 aliceNativeBefore = ALICE.balance;
    uint256 aliceERC20Before = mockERC20.balanceOf(ALICE);
    uint256 harnessERC20Before = mockERC20.balanceOf(address(harness));

    harness.exposed_transferNonNativeAssetsIn(terms, ALICE, address(harness));

    // Native not transferred
    assertEq(ALICE.balance, aliceNativeBefore);
    // ERC20 assets transferred
    assertEq(aliceERC20Before - mockERC20.balanceOf(ALICE), 100 ether);
    assertEq(mockERC20.balanceOf(address(harness)) - harnessERC20Before, 100 ether);
  }

  function test_transferNonNativeAssetsIn_transfersERC20Collateral() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeERC20Asset(50 ether), // ERC20 collateral
      _makeERC20Asset(100 ether).toArray()
    );

    uint256 aliceBefore = mockERC20.balanceOf(ALICE);
    uint256 harnessBefore = mockERC20.balanceOf(address(harness));

    harness.exposed_transferNonNativeAssetsIn(terms, ALICE, address(harness));

    // Both collateral and assets transferred
    assertEq(aliceBefore - mockERC20.balanceOf(ALICE), 150 ether);
    assertEq(mockERC20.balanceOf(address(harness)) - harnessBefore, 150 ether);
  }

  function test_transferNonNativeAssetsIn_transfersNonNativeAssets() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeNativeAsset(1 ether), // Native collateral skipped
      _makeERC20Asset(100 ether).toArray()
    );

    uint256 aliceBefore = mockERC20.balanceOf(ALICE);

    harness.exposed_transferNonNativeAssetsIn(terms, ALICE, address(harness));

    assertEq(aliceBefore - mockERC20.balanceOf(ALICE), 100 ether);
  }

  function test_transferNonNativeAssetsIn_skipsNativeAssets() public {
    Asset[] memory mixedAssets = AssetHelper.toArray(_makeNativeAsset(1 ether), _makeERC20Asset(100 ether));

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, DEFAULT_DEADLINE, _makeNativeAsset(0.5 ether), mixedAssets
    );

    uint256 aliceNativeBefore = ALICE.balance;
    uint256 aliceERC20Before = mockERC20.balanceOf(ALICE);

    harness.exposed_transferNonNativeAssetsIn(terms, ALICE, address(harness));

    // Native not transferred
    assertEq(ALICE.balance, aliceNativeBefore);
    // Only ERC20 transferred
    assertEq(aliceERC20Before - mockERC20.balanceOf(ALICE), 100 ether);
  }

  function test_transferNonNativeAssetsIn_mixedCollateralAndAssets() public {
    Asset[] memory mixedAssets = new Asset[](3);
    mixedAssets[0] = _makeNativeAsset(1 ether); // Skipped
    mixedAssets[1] = _makeERC20Asset(100 ether); // Transferred
    mixedAssets[2] = _makeERC1155Asset(1, 50); // Transferred

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeERC20Asset(25 ether), // ERC20 collateral - transferred
      mixedAssets
    );

    uint256 aliceERC20Before = mockERC20.balanceOf(ALICE);
    uint256 aliceERC1155Before = mockERC1155.balanceOf(ALICE, 1);
    uint256 aliceNativeBefore = ALICE.balance;

    harness.exposed_transferNonNativeAssetsIn(terms, ALICE, address(harness));

    // Native not transferred
    assertEq(ALICE.balance, aliceNativeBefore);
    // ERC20 collateral + assets transferred (25 + 100)
    assertEq(aliceERC20Before - mockERC20.balanceOf(ALICE), 125 ether);
    // ERC1155 transferred
    assertEq(aliceERC1155Before - mockERC1155.balanceOf(ALICE, 1), 50);
  }

  function test_transferNonNativeAssetsIn_transfersERC721Collateral() public {
    uint256 tokenId = 1;
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeERC721Asset(tokenId), // ERC721 collateral
      _makeERC20Asset(100 ether).toArray()
    );

    assertEq(mockERC721.ownerOf(tokenId), ALICE);

    harness.exposed_transferNonNativeAssetsIn(terms, ALICE, address(harness));

    assertEq(mockERC721.ownerOf(tokenId), address(harness));
  }

  function test_transferNonNativeAssetsIn_transfersERC1155Collateral() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeERC1155Asset(1, 100), // ERC1155 collateral
      _makeERC20Asset(100 ether).toArray()
    );

    uint256 aliceBefore = mockERC1155.balanceOf(ALICE, 1);

    harness.exposed_transferNonNativeAssetsIn(terms, ALICE, address(harness));

    assertEq(aliceBefore - mockERC1155.balanceOf(ALICE, 1), 100);
  }

  function test_transferNonNativeAssetsIn_emptyAssets() public {
    Asset[] memory emptyAssets = new Asset[](0);
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, DEFAULT_DEADLINE, _makeERC20Asset(50 ether), emptyAssets
    );

    uint256 aliceBefore = mockERC20.balanceOf(ALICE);

    harness.exposed_transferNonNativeAssetsIn(terms, ALICE, address(harness));

    // Only collateral transferred
    assertEq(aliceBefore - mockERC20.balanceOf(ALICE), 50 ether);
  }
}
