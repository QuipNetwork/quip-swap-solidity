// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';
import {Terms, TermsLib} from '../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../harness/OmnibusHarness.sol';
import {VerifierMock} from '../mocks/VerifierMock.sol';
import {WalletFactoryMock} from '../mocks/WalletFactoryMock.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {AuthHelper} from '../utils/AuthHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';

/// @title Cross-Chain Double-Spend (two-chain model)
/// @dev A genuine two-chain simulation (two Omnibus instances, vm.chainId per op): the
/// proposer's leg lives on chain A, the taker's on chain B, storage is INDEPENDENT. The only
/// thing preventing a proposer from taking the taker's leg on B and then reclaiming their own
/// on A is the WINDOW ordering: the taker's redeem window on A, [proposer.claimDeadline,
/// proposer.reclaimRelease), closes exactly when the proposer's reclaim opens. These pin that
/// boundary so "claim on B, reclaim on A" can never double-spend while the taker still had a
/// chance to redeem.
contract Omnibus_CrossChainDoubleSpend is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  uint256 constant CHAIN_A = 111; // proposer's chain
  uint256 constant CHAIN_B = 222; // taker's chain

  uint256 constant A_COMMIT = 1000;
  uint256 constant B_COMMIT = 2000;
  uint256 constant A_CLAIM = 3000;
  uint256 constant B_CLAIM = 4000;
  uint256 constant A_RECLAIM = 5000;
  uint256 constant B_RECLAIM = 6000;

  address ALICE = makeAddr('alice'); // proposer (holds secret)
  address BOB = makeAddr('bob'); // taker
  address ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address BOB_RECIPIENT = makeAddr('bobRecipient');
  address ALICE_RECLAIM = makeAddr('aliceReclaim');
  address BOB_RECLAIM = makeAddr('bobReclaim');

  OmnibusHarness omnibusA; // chain A (proposer leg)
  OmnibusHarness omnibusB; // chain B (taker leg)
  VerifierMock verifier;
  bytes32 constant SECRET = keccak256('secret');
  bytes32 lock;

  function setUp() public {
    verifier = new VerifierMock();
    omnibusA = new OmnibusHarness(address(this), address(new WalletFactoryMock()));
    omnibusB = new OmnibusHarness(address(this), address(new WalletFactoryMock()));
    omnibusA.setVerifierActivity(address(verifier), true);
    omnibusB.setVerifierActivity(address(verifier), true);
    lock = omnibusA.exposed_generateLock(SECRET);
    vm.deal(ALICE, 10 ether);
    vm.deal(BOB, 10 ether);
  }

  function _alice() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      CHAIN_A, ALICE_RECLAIM, ALICE_RECIPIENT, A_COMMIT, A_CLAIM, A_RECLAIM, AssetHelper.makeNative(1 ether).toArray()
    );
  }

  function _bob() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      CHAIN_B, BOB_RECLAIM, BOB_RECIPIENT, B_COMMIT, B_CLAIM, B_RECLAIM, AssetHelper.makeNative(1 ether).toArray()
    );
  }

  // proposer commits her leg on chain A; taker commits his on chain B
  function _commitBothChains() internal {
    Terms memory alice = _alice();
    Terms memory bob = _bob();

    vm.chainId(CHAIN_A);
    vm.warp(500); // proposer commit window [0, A_COMMIT)
    vm.prank(ALICE);
    omnibusA.commit{value: 1 ether}(lock, alice, bob, AuthHelper.keyedAuth(address(verifier), ALICE));
    assertEq(uint8(omnibusA.lockState(omnibusA.swapId(lock, alice, bob))), uint8(LockState.Committed));

    vm.chainId(CHAIN_B);
    vm.warp(1500); // taker commit window [A_COMMIT, B_COMMIT)
    vm.prank(BOB);
    omnibusB.commit{value: 1 ether}(lock, bob, alice, AuthHelper.keyedAuth(address(verifier), BOB));
    assertEq(uint8(omnibusB.lockState(omnibusB.swapId(lock, alice, bob))), uint8(LockState.Committed));
  }

  /// @notice happy path: proposer claims on B, taker redeems on A. Both legs settle to the
  /// right recipients, and the proposer's attempt to ALSO reclaim on A reverts (no double-spend)
  function test_crossChain_fairSwap_proposerCannotAlsoReclaim() public {
    Terms memory alice = _alice();
    Terms memory bob = _bob();
    _commitBothChains();

    // proposer reveals on chain B, taking the taker's leg
    vm.chainId(CHAIN_B);
    vm.warp(2500); // reveal window [B_COMMIT, A_CLAIM)
    omnibusB.claim(SECRET, alice, bob);
    assertEq(ALICE_RECIPIENT.balance, 1 ether, 'proposer took taker leg on B');

    // taker redeems on chain A with the now-public secret
    vm.chainId(CHAIN_A);
    vm.warp(4000); // redeem window [A_CLAIM, A_RECLAIM)
    omnibusA.claim(SECRET, bob, alice);
    assertEq(BOB_RECIPIENT.balance, 1 ether, 'taker redeemed proposer leg on A');

    // proposer now tries to ALSO reclaim her leg on A -> chain A is already Spent
    vm.warp(5500); // past A_RECLAIM
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibusA.reclaim(lock, alice, bob);
    assertEq(ALICE_RECLAIM.balance, 0, 'proposer cannot double-spend her own leg');
  }

  /// @notice the safety boundary: after claiming on B, the proposer CANNOT reclaim on A during
  /// the taker's redeem window. Reclaim only opens at A_RECLAIM, exactly when redeem closes
  function test_crossChain_proposerCannotReclaimDuringTakerRedeemWindow() public {
    Terms memory alice = _alice();
    Terms memory bob = _bob();
    _commitBothChains();

    vm.chainId(CHAIN_B);
    vm.warp(2500);
    omnibusB.claim(SECRET, alice, bob); // proposer took taker leg, secret public

    // chain A: still inside the taker's redeem window [A_CLAIM, A_RECLAIM) -> reclaim closed
    vm.chainId(CHAIN_A);
    vm.warp(A_RECLAIM - 1);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibusA.reclaim(lock, alice, bob);

    // the taker can still redeem at this instant
    omnibusA.claim(SECRET, bob, alice);
    assertEq(BOB_RECIPIENT.balance, 1 ether, 'taker redeem still available inside its window');
  }

  /// @notice documented reaction-buffer outcome: if the taker never redeems on A, the proposer
  /// recovers her own leg after A_RECLAIM. She ends with both legs -- the taker's negligence,
  /// gated correctly by the window, not a contract flaw
  function test_crossChain_negligentTaker_proposerRecoversAfterWindow() public {
    Terms memory alice = _alice();
    Terms memory bob = _bob();
    _commitBothChains();

    vm.chainId(CHAIN_B);
    vm.warp(2500);
    omnibusB.claim(SECRET, alice, bob); // proposer took taker leg
    assertEq(ALICE_RECIPIENT.balance, 1 ether);

    // taker never redeems on chain A; after A_RECLAIM the proposer reclaims her own leg
    vm.chainId(CHAIN_A);
    vm.warp(5500);
    omnibusA.reclaim(lock, alice, bob);
    assertEq(ALICE_RECLAIM.balance, 1 ether, 'proposer recovers her leg after the redeem window lapsed');
    assertEq(BOB_RECIPIENT.balance, 0, 'taker forfeited by missing its redeem window');
  }
}
