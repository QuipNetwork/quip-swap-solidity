// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {AuthHelper} from '../../utils/AuthHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {Ownable} from '@openzeppelin-contracts-5.7.0/access/Ownable.sol';

/// @title Omnibus setVerifierActivity Tests
/// @dev Admin + lifecycle behavior of the ERC-7913 verifier allowlist. Activity is
/// checked ONLY at commit time (the keyed route); claim/reclaim never touch the
/// router, so deactivating a verifier mid-swap strands nothing
contract Omnibus_setVerifierActivity is OmnibusTest {
  function test_setVerifierActivity_ownerCanActivateAndDeactivate() public {
    assertFalse(omnibus.verifierActive(address(verifierB)));

    omnibus.setVerifierActivity(address(verifierB), true);
    assertTrue(omnibus.verifierActive(address(verifierB)));

    omnibus.setVerifierActivity(address(verifierB), false);
    assertFalse(omnibus.verifierActive(address(verifierB)));
  }

  function test_setVerifierActivity_emitsEvent() public {
    vm.expectEmit(true, false, false, true);
    emit IOmnibus.VerifierActivityUpdated(address(verifierB), true);
    omnibus.setVerifierActivity(address(verifierB), true);

    vm.expectEmit(true, false, false, true);
    emit IOmnibus.VerifierActivityUpdated(address(verifierB), false);
    omnibus.setVerifierActivity(address(verifierB), false);
  }

  function test_setVerifierActivity_revertsWhen_notOwner() public {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
    vm.prank(ALICE);
    omnibus.setVerifierActivity(address(verifierB), true);
  }

  function test_setVerifierActivity_revertsWhen_zeroVerifier() public {
    vm.expectRevert(IOmnibus.ZeroVerifier.selector);
    omnibus.setVerifierActivity(address(0), true);
  }

  function test_setVerifierActivity_deactivationMidSwap_blocksNewCommitsNotClaims() public {
    // activate A + B; Alice opens a swap under an A-keyed identity
    omnibus.setVerifierActivity(address(verifierB), true);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    _commitFor(ALICE, lock, alice, bob); // keyed via verifierA
    _assertSwapState(lock, alice, bob, LockState.Free);

    // deactivate A mid-swap: NEW A-keyed commits fail closed...
    omnibus.setVerifierActivity(address(verifierA), false);

    bytes32 freshLock = omnibus.exposed_generateLock(keccak256('fresh-secret'));
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.VerifierNotActive.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(freshLock, alice, bob, AuthHelper.auth(aliceSigner));

    // ...B is unaffected...
    bytes memory bViaSigner = abi.encodePacked(address(verifierB), bytes('alice-key'));
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(freshLock, alice, bob, AuthHelper.auth(bViaSigner));

    // ...and the swap already pinned under the deactivated verifier still settles:
    // Bob posts his side keyed via the still-active B and Alice claims — no
    // verifier call in claim
    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bob, alice, AuthHelper.auth(abi.encodePacked(address(verifierB), bytes('bob-key'))));
    _warpToProposerClaim();
    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT), DEFAULT_AMOUNT);
    assertEq(BOB_RECIPIENT.balance, DEFAULT_AMOUNT);
  }
}
