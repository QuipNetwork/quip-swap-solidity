// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus/Omnibus.t.sol';

/// a contract that rejects native transfers, standing in for a hostile recipient/reclaimRecipient
contract RejectingRecipient {
  receive() external payable {
    revert('rejecting');
  }
}

/// @title Settlement Hostage Neutralized (audit finding)
/// @dev The finding: a party controls their own recipient/reclaimRecipient and can point it at
/// a rejecting contract to veto settlement and hold the counterparty's healthy leg hostage.
/// Independent reclaim neutralizes it: a hostile recipient becomes pure self-harm, and the
/// counterparty always recovers their own leg regardless.
contract Omnibus_SettlementHostage is OmnibusTest {
  RejectingRecipient internal hostile;

  function setUp() public override {
    super.setUp();
    hostile = new RejectingRecipient();
  }

  /// @notice reclaim hostage: Bob points his reclaimRecipient at a rejecting contract. Under
  /// independent reclaim this can no longer block Alice — she recovers her own leg in full,
  /// and only Bob's own reclaim reverts (self-harm)
  function test_hostage_reclaim_hostileCounterpartyRecipientCannotBlockParty() public {
    Terms memory alice = _aliceTermsOn(block.chainid, _makeNativeAssets(DEFAULT_AMOUNT)); // ALICE reclaimRecipient
    // Bob's reclaimRecipient is the rejecting contract
    Terms memory bob = _makeTerms(
      block.chainid,
      address(hostile),
      BOB_RECIPIENT,
      BOB_COMMIT_DEADLINE,
      BOB_CLAIM_DEADLINE,
      BOB_RECLAIM_RELEASE,
      _makeNativeAssets(DEFAULT_AMOUNT)
    );

    _commitBothParties(lock, alice, bob);

    // Alice reclaims her own leg -> succeeds, fully unaffected by Bob's hostile recipient
    _warpToProposerReclaim();
    uint256 aliceBefore = ALICE.balance;
    omnibus.reclaim(lock, alice, bob);
    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT, 'party recovers despite hostile counterparty');

    // Bob's own reclaim reverts on his rejecting recipient (self-harm), but it never held Alice
    _warpToTakerReclaim();
    vm.expectRevert();
    omnibus.reclaim(lock, bob, alice);
  }

  /// @notice claim hostage -> recovery: Bob points his recipient at a rejecting contract, so the
  /// atomic claim reverts (swap fails). Alice is not stuck: she recovers her own leg via
  /// independent reclaim
  function test_hostage_claim_vetoDefusedByIndependentReclaim() public {
    Terms memory alice = _aliceTermsOn(block.chainid, _makeNativeAssets(DEFAULT_AMOUNT));
    // Bob's recipient (claim payout destination) is the rejecting contract
    Terms memory bob = _makeTerms(
      block.chainid,
      BOB,
      address(hostile),
      BOB_COMMIT_DEADLINE,
      BOB_CLAIM_DEADLINE,
      BOB_RECLAIM_RELEASE,
      _makeNativeAssets(DEFAULT_AMOUNT)
    );

    _commitBothParties(lock, alice, bob);

    // claim settles both legs atomically; Bob's hostile recipient makes it revert (swap fails)
    _warpToProposerClaim();
    vm.expectRevert();
    omnibus.claim(SECRET, alice, bob);

    // Alice is not held hostage: she reclaims her own leg after her release
    _warpToProposerReclaim();
    uint256 aliceBefore = ALICE.balance;
    omnibus.reclaim(lock, alice, bob);
    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT, 'party recovers after a vetoed claim');
  }
}
