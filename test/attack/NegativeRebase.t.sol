// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

import {Terms} from '../../src/TermsLib.sol';
import {LockState} from '../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../harness/OmnibusHarness.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {VerifierMock} from '../mocks/VerifierMock.sol';
import {WalletFactoryMock} from '../mocks/WalletFactoryMock.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {AuthHelper} from '../utils/AuthHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';

/// @title Negative Rebase / Slashable Token (freeze neutralized by clamped reclaim)
/// @dev Escrow accounting assumes balances change only via transfers; commit reconciles
/// exact receipt ONCE. A balance-mutable token (rebasing, slashable) can shrink the pooled
/// escrow in place afterwards, making the declared payout underfunded. The audited grief:
/// every payout reverted forever — both legs frozen, and with pooled escrow the last
/// settler bore the whole loss AND the freeze. The fix is asymmetric by design:
/// - claim stays exact-or-revert: revealing the secret is conditional on receiving exactly
///   what was priced, so a slash-to-dust front-run can never buy the secret at a discount
/// - reclaim clamps fungible payouts to the held balance (TermsLib.transferAssetsClamped):
///   it is the terminal backstop and must never brick; earlier reclaims are paid in full
///   and the last is paid the remainder
/// These tests pin both halves so a regression in either direction is caught.
contract Omnibus_NegativeRebase is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // lifecycle deadlines (proposer < taker, strictly interleaved)
  uint256 constant A_COMMIT = 1000;
  uint256 constant B_COMMIT = 2000;
  uint256 constant A_CLAIM = 3000;
  uint256 constant B_CLAIM = 4000;
  uint256 constant A_RECLAIM = 5000;
  uint256 constant B_RECLAIM = 6000;

  uint256 constant OTHER_CHAIN_ID = 999;
  uint256 constant AMOUNT = 100 ether;

  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public CHARLIE = makeAddr('charlie');
  address public ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  OmnibusHarness public omnibus;
  VerifierMock public verifier;
  ERC20Mock public token; // burn() simulates a negative rebase / slash

  bytes32 public constant SECRET = keccak256('secret');
  bytes32 public lock;

  function setUp() public {
    verifier = new VerifierMock();
    omnibus = new OmnibusHarness(address(this), address(new WalletFactoryMock()));
    omnibus.setVerifierActivity(address(verifier), true);
    lock = omnibus.exposed_generateLock(SECRET);
    token = new ERC20Mock('Rebase', 'REB', 18);
    vm.deal(ALICE, 100 ether);
    token.mint(BOB, AMOUNT);
    vm.prank(BOB);
    token.approve(address(omnibus), type(uint256).max);
  }

  function _aliceNative(uint256 amount) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, A_COMMIT, A_CLAIM, A_RECLAIM, AssetHelper.makeNative(amount).toArray()
    );
  }

  function _bobToken(uint256 amount) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      B_COMMIT,
      B_CLAIM,
      B_RECLAIM,
      AssetHelper.makeERC20(address(token), amount).toArray()
    );
  }

  /// @dev commits the same-chain pairing: Alice's native proposer leg, Bob's token taker leg
  function _commitBoth(Terms memory alice, Terms memory bob) internal {
    vm.warp(500); // proposer commit window
    vm.prank(ALICE);
    omnibus.commit{value: 1 ether}(lock, alice, bob, AuthHelper.keyedAuth(address(verifier), ALICE));
    vm.warp(1500); // taker commit window [A_COMMIT, B_COMMIT)
    vm.prank(BOB);
    omnibus.commit(lock, bob, alice, AuthHelper.keyedAuth(address(verifier), BOB));
  }

  /// @notice REGRESSION: claim must stay exact-or-revert. If a shortfall could be paid
  /// clamped, a cross-chain attacker could front-run the victim's claim with a slash to
  /// dust: the victim would receive dust yet publish the secret, and the attacker would
  /// take the victim's full leg on the other chain
  function test_negativeRebase_claimStaysExactOrRevert() public {
    Terms memory alice = _aliceNative(1 ether);
    Terms memory bob = _bobToken(AMOUNT);
    _commitBoth(alice, bob);

    // negative rebase: 1 wei short of Bob's declared amount
    token.burn(address(omnibus), 1);

    vm.warp(2500); // proposer claim window [B_COMMIT, A_CLAIM)
    vm.prank(ALICE);
    vm.expectRevert(SafeTransferLib.TransferFailed.selector);
    omnibus.claim(SECRET, alice, bob);

    // the secret was never published on-chain; the swap falls through to reclaims
    assertEq(uint8(omnibus.lockState(omnibus.swapId(lock, alice, bob))), uint8(LockState.Committed));
  }

  /// @notice REGRESSION (audit): before clamped reclaim this scenario froze BOTH legs
  /// forever — claim and every reclaim reverted on the underfunded transfer. Now the
  /// trade aborts into reclaim: the healthy native leg is recovered in full and the
  /// degraded token leg pays the remainder
  function test_negativeRebase_escrowNeverFrozen() public {
    Terms memory alice = _aliceNative(1 ether);
    Terms memory bob = _bobToken(AMOUNT);
    _commitBoth(alice, bob);

    token.burn(address(omnibus), 1);

    // claim is blocked (exact-or-revert) ...
    vm.warp(2500);
    vm.prank(ALICE);
    vm.expectRevert(SafeTransferLib.TransferFailed.selector);
    omnibus.claim(SECRET, alice, bob);

    // ... but reclaim is not: each side independently recovers its own leg
    uint256 aliceBefore = ALICE.balance;
    vm.warp(A_RECLAIM + 1);
    omnibus.reclaim(lock, alice, bob); // healthy native leg, in full
    vm.warp(B_RECLAIM + 1);
    omnibus.reclaim(lock, bob, alice); // shrunk token leg, clamped remainder

    assertEq(ALICE.balance - aliceBefore, 1 ether, 'healthy native leg recovered in full');
    assertEq(token.balanceOf(BOB), AMOUNT - 1, 'token leg pays the clamped remainder');
    assertEq(uint8(omnibus.lockState(omnibus.swapId(lock, alice, bob))), uint8(LockState.Spent));
  }

  /// @notice REGRESSION (audit): the pooled face. Two swaps escrow the same token; after
  /// a -10% rebase the first reclaimer is paid in full and the last was frozen forever.
  /// Clamping keeps the first-come-first-served allocation but the last settler now exits
  /// with the remainder instead of nothing
  function test_negativeRebase_pooledLastSettlerGetsRemainder() public {
    token.mint(ALICE, AMOUNT);
    vm.prank(ALICE);
    token.approve(address(omnibus), type(uint256).max);

    // two independent cross-chain proposer legs, each escrowing AMOUNT of the same token
    Terms memory remote = TermsHelper.makeTerms(
      OTHER_CHAIN_ID, CHARLIE, CHARLIE, B_COMMIT, B_CLAIM, B_RECLAIM, AssetHelper.makeNative(1 ether).toArray()
    );
    Terms memory aliceLeg = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      A_COMMIT,
      A_CLAIM,
      A_RECLAIM,
      AssetHelper.makeERC20(address(token), AMOUNT).toArray()
    );
    Terms memory bobLeg = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      A_COMMIT,
      A_CLAIM,
      A_RECLAIM,
      AssetHelper.makeERC20(address(token), AMOUNT).toArray()
    );

    bytes32 l1 = omnibus.exposed_generateLock(keccak256('swap-a'));
    bytes32 l2 = omnibus.exposed_generateLock(keccak256('swap-b'));
    vm.warp(500);
    vm.prank(ALICE);
    omnibus.commit(l1, aliceLeg, remote, AuthHelper.keyedAuth(address(verifier), ALICE));
    vm.prank(BOB);
    omnibus.commit(l2, bobLeg, remote, AuthHelper.keyedAuth(address(verifier), BOB));
    assertEq(token.balanceOf(address(omnibus)), 2 * AMOUNT);

    // -10% rebase across the pooled escrow, no transfer involved
    token.burn(address(omnibus), 20 ether);

    vm.warp(A_RECLAIM + 1);
    omnibus.reclaim(l1, aliceLeg, remote);
    assertEq(token.balanceOf(ALICE), AMOUNT, 'first reclaimer is paid in full');

    // before the fix this reverted forever; now the last settler exits with the remainder
    omnibus.reclaim(l2, bobLeg, remote);
    assertEq(token.balanceOf(BOB), AMOUNT - 20 ether, 'last reclaimer gets the remainder');
    assertEq(token.balanceOf(address(omnibus)), 0);
    assertEq(uint8(omnibus.lockState(omnibus.swapId(l2, bobLeg, remote))), uint8(LockState.Spent));
  }
}
