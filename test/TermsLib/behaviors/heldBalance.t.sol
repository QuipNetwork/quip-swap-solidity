// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';

/// @title TermsLib heldBalance Tests
/// @dev Tests for TermsLib.heldBalance
contract TermsLib_heldBalance is TermsLibTest {
  using AssetHelper for *;

  // ============ Success Cases (ERC20) ============

  function test_heldBalance_erc20_returnsBalance() public view {
    Asset memory asset = _makeERC20Asset(0);

    uint256 balance = harness.exposed_heldBalance(asset, ALICE);
    assertEq(balance, 1_000_000 ether); // minted in setUp
  }

  function test_heldBalance_erc20_zeroForFundlessAccount() public view {
    Asset memory asset = _makeERC20Asset(0);

    uint256 balance = harness.exposed_heldBalance(asset, ALICE_RECIPIENT);
    assertEq(balance, 0);
  }

  function test_heldBalance_erc20_ignoresAssetAmountField() public view {
    // the `amount` field of the asset must not influence the read
    uint256 a = harness.exposed_heldBalance(_makeERC20Asset(0), ALICE);
    uint256 b = harness.exposed_heldBalance(_makeERC20Asset(type(uint256).max), ALICE);

    assertEq(a, b);
    assertEq(a, 1_000_000 ether);
  }

  function test_heldBalance_erc20_reflectsBalanceChange() public {
    Asset memory asset = _makeERC20Asset(0);

    uint256 before = harness.exposed_heldBalance(asset, ALICE);

    vm.prank(ALICE);
    mockERC20.transfer(BOB, 100 ether);

    uint256 afterBal = harness.exposed_heldBalance(asset, ALICE);
    assertEq(before - afterBal, 100 ether);
  }

  // ============ Success Cases (ERC1155) ============

  function test_heldBalance_erc1155_returnsBalance() public view {
    Asset memory asset = _makeERC1155Asset(1, 0);

    uint256 balance = harness.exposed_heldBalance(asset, ALICE);
    assertEq(balance, 1000); // minted id 1 to ALICE in setUp
  }

  function test_heldBalance_erc1155_zeroForUnownedId() public view {
    // ALICE holds id 1, but not id 2
    Asset memory asset = _makeERC1155Asset(2, 0);

    uint256 balance = harness.exposed_heldBalance(asset, ALICE);
    assertEq(balance, 0);
  }

  function test_heldBalance_erc1155_isPerIdIsolated() public view {
    // BOB holds id 2 only
    assertEq(harness.exposed_heldBalance(_makeERC1155Asset(2, 0), BOB), 1000);
    assertEq(harness.exposed_heldBalance(_makeERC1155Asset(1, 0), BOB), 0);
  }

  function test_heldBalance_erc1155_zeroForFundlessAccount() public view {
    Asset memory asset = _makeERC1155Asset(1, 0);

    uint256 balance = harness.exposed_heldBalance(asset, ALICE_RECIPIENT);
    assertEq(balance, 0);
  }

  function test_heldBalance_erc1155_ignoresAssetAmountField() public view {
    uint256 a = harness.exposed_heldBalance(_makeERC1155Asset(1, 0), ALICE);
    uint256 b = harness.exposed_heldBalance(_makeERC1155Asset(1, type(uint256).max), ALICE);

    assertEq(a, b);
    assertEq(a, 1000);
  }

  function test_heldBalance_erc1155_reflectsBalanceChange() public {
    Asset memory asset = _makeERC1155Asset(1, 0);

    uint256 before = harness.exposed_heldBalance(asset, ALICE);

    vm.prank(ALICE);
    mockERC1155.safeTransferFrom(ALICE, BOB, 1, 250, '');

    uint256 afterBal = harness.exposed_heldBalance(asset, ALICE);
    assertEq(before - afterBal, 250);
  }

  // ============ Edge Cases ============

  function test_heldBalance_erc721_usesErc20StylePath() public view {
    // non-ERC1155 assets read through the ERC20 balanceOf path; for ERC721
    // this yields the owner's token count. ALICE owns tokens 1 and 2.
    Asset memory asset = _makeERC721Asset(1);

    uint256 balance = harness.exposed_heldBalance(asset, ALICE);
    assertEq(balance, 2);
  }

  // ============ Fuzz Tests ============

  function testFuzz_heldBalance_erc20(address account, uint256 amount) public {
    vm.assume(account != address(0));
    deal(address(mockERC20), account, amount);

    uint256 balance = harness.exposed_heldBalance(_makeERC20Asset(0), account);
    assertEq(balance, amount);
  }

  function testFuzz_heldBalance_erc1155(uint256 id, uint256 amount) public {
    amount = bound(amount, 0, type(uint128).max);
    address holder = makeAddr('holder');
    if (amount > 0) mockERC1155.mint(holder, id, amount, '');

    uint256 balance = harness.exposed_heldBalance(_makeERC1155Asset(id, 0), holder);
    assertEq(balance, amount);
  }
}
