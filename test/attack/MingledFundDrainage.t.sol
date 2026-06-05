// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Terms} from '../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../harness/OmnibusHarness.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';

/// @title Mingled Fund Drainage
/// @dev regression tests for the commingled-pool drain. commit only escrows
/// `party`, but the canonical digest and chainId-only role checks made the two
/// sides interchangeable at payout, and nothing recorded which side deposited.
/// an attacker could post the cheap side, then redeem the never-posted expensive
/// side out of other users' pooled deposits. the per-lock `posted` tracking must
/// block both the reclaim path (one commit -> Free) and the execute path
/// (two commits of the same side -> Committed).
contract Omnibus_MingledFundDrainage is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 constant CHEAP_NATIVE = 1 wei;
  uint256 constant POOLED_USDC = 1_000_000 ether;

  // ============ Actors ============

  address public VICTIM = makeAddr('victim');
  address public ATTACKER = makeAddr('attacker');

  // ============ Contracts ============

  OmnibusHarness public omnibus;
  ERC20Mock public usdc;

  // ============ Setup ============

  function setUp() public {
    omnibus = new OmnibusHarness(address(this));
    usdc = new ERC20Mock('USD Coin', 'USDC', 6);

    vm.deal(ATTACKER, 100 ether);

    // a victim escrows a large USDC deposit into the singleton; these are the
    // commingled funds an attacker would try to drain from an unrelated lock
    usdc.mint(VICTIM, POOLED_USDC);
    _poolVictimFunds();
  }

  /// @notice victim opens an honest swap, leaving their USDC pooled in the omnibus
  function _poolVictimFunds() internal {
    Terms memory victimTerms = TermsHelper.makeTerms(
      block.chainid,
      VICTIM,
      VICTIM,
      uint64(block.timestamp + 1 days),
      AssetHelper.makeERC20(address(usdc), POOLED_USDC).toArray()
    );
    // the counterparty side is never collected; its contents are irrelevant here
    Terms memory counterpartyTerms = TermsHelper.makeTerms(
      block.chainid,
      VICTIM,
      VICTIM,
      uint64(block.timestamp + 1 days),
      AssetHelper.makeNative(1 ether).toArray()
    );

    vm.startPrank(VICTIM);
    usdc.approve(address(omnibus), type(uint256).max);
    omnibus.commit(omnibus.exposed_generateLock(keccak256('victim-secret')), victimTerms, counterpartyTerms);
    vm.stopPrank();

    assertEq(usdc.balanceOf(address(omnibus)), POOLED_USDC);
  }

  /// @notice builds the cheap side the attacker actually posts (1 wei native)
  function _cheapSide(uint64 deadline) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      ATTACKER,
      ATTACKER,
      deadline,
      AssetHelper.makeNative(CHEAP_NATIVE).toArray()
    );
  }

  /// @notice builds the expensive side the attacker never posts (the whole pool, payable to itself)
  function _expensiveSide(uint64 deadline) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      ATTACKER,
      ATTACKER,
      deadline,
      AssetHelper.makeERC20(address(usdc), POOLED_USDC).toArray()
    );
  }

  // ============ Reclaim path: one commit -> Free ============

  /// @notice posting only the cheap side then reclaiming the expensive side reverts
  function test_attack_reclaim_unpostedSideCannotDrainPool() public {
    uint64 deadline = uint64(block.timestamp + 1 hours);
    bytes32 lock = omnibus.exposed_generateLock(keccak256('attacker-secret'));
    Terms memory cheap = _cheapSide(deadline);
    Terms memory expensive = _expensiveSide(deadline);

    // attacker posts only the cheap side -> lock reaches Free with 1 wei escrowed
    vm.prank(ATTACKER);
    omnibus.commit{value: CHEAP_NATIVE}(lock, cheap, expensive);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    // after the attacker-chosen deadline, reclaim with the roles flipped: the
    // never-posted expensive side as `party`. payout is gated on `posted`.
    vm.warp(deadline + 1);

    vm.expectRevert(IOmnibus.TermsNotPosted.selector);
    vm.prank(ATTACKER);
    omnibus.reclaim(lock, expensive, cheap);

    // pool intact, attacker drained nothing
    assertEq(usdc.balanceOf(address(omnibus)), POOLED_USDC);
    assertEq(usdc.balanceOf(ATTACKER), 0);
  }

  // ============ Execute path: two commits -> Committed ============

  /// @notice re-posting the same side to force Committed reverts before execute is reachable
  function test_attack_execute_cannotRepostSameSideTwice() public {
    uint64 deadline = uint64(block.timestamp + 1 hours);
    bytes32 lock = omnibus.exposed_generateLock(keccak256('attacker-secret-2'));
    Terms memory cheap = _cheapSide(deadline);
    Terms memory expensive = _expensiveSide(deadline);

    // first commit posts the cheap side -> Free
    vm.prank(ATTACKER);
    omnibus.commit{value: CHEAP_NATIVE}(lock, cheap, expensive);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    // re-posting the SAME cheap side would drive Free -> Committed, which execute
    // treats as "both sides posted"; the guard rejects the second post
    vm.expectRevert(IOmnibus.TermsAlreadyPosted.selector);
    vm.prank(ATTACKER);
    omnibus.commit{value: CHEAP_NATIVE}(lock, cheap, expensive);

    // never reached the drainable Committed state; pool intact
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));
    assertEq(usdc.balanceOf(address(omnibus)), POOLED_USDC);
    assertEq(usdc.balanceOf(ATTACKER), 0);
  }
}
