// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {Ownable} from '@openzeppelin-contracts-5.6.0-rc.1/access/Ownable.sol';

/// @title Omnibus setVerifierTrust Tests
/// @dev Admin + lifecycle behavior of the ERC-7913 verifier allowlist. Trust is
/// checked ONLY at commit time (the keyed route); claim/reclaim never touch the
/// router, so revoking a verifier mid-swap strands nothing
contract Omnibus_setVerifierTrust is OmnibusTest {
  function test_setVerifierTrust_ownerCanTrustAndRevoke() public {
    assertFalse(omnibus.trustedVerifiers(address(verifierB)));

    omnibus.setVerifierTrust(address(verifierB), true);
    assertTrue(omnibus.trustedVerifiers(address(verifierB)));

    omnibus.setVerifierTrust(address(verifierB), false);
    assertFalse(omnibus.trustedVerifiers(address(verifierB)));
  }

  function test_setVerifierTrust_emitsEvent() public {
    vm.expectEmit(true, false, false, true);
    emit IOmnibus.VerifierTrustUpdated(address(verifierB), true);
    omnibus.setVerifierTrust(address(verifierB), true);

    vm.expectEmit(true, false, false, true);
    emit IOmnibus.VerifierTrustUpdated(address(verifierB), false);
    omnibus.setVerifierTrust(address(verifierB), false);
  }

  function test_setVerifierTrust_revertsWhen_notOwner() public {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
    vm.prank(ALICE);
    omnibus.setVerifierTrust(address(verifierB), true);
  }

  function test_setVerifierTrust_revertsWhen_zeroVerifier() public {
    vm.expectRevert(IOmnibus.ZeroVerifier.selector);
    omnibus.setVerifierTrust(address(0), true);
  }

  function test_setVerifierTrust_revocationMidSwap_blocksNewCommitsNotClaims() public {
    // trust A + B; Alice opens a swap under an A-keyed identity
    omnibus.setVerifierTrust(address(verifierB), true);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    _commitFor(ALICE, lock, alice, bob); // keyed via verifierA
    _assertLockState(lock, LockState.Free);

    // revoke A mid-swap: NEW A-keyed commits fail closed...
    omnibus.setVerifierTrust(address(verifierA), false);

    bytes32 freshLock = omnibus.exposed_generateLock(keccak256('fresh-secret'));
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.UntrustedVerifier.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(freshLock, alice, bob, _keyedAuth(aliceSigner));

    // ...B is unaffected...
    bytes memory bViaSigner = abi.encodePacked(address(verifierB), bytes('alice-key'));
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(freshLock, alice, bob, _keyedAuth(bViaSigner));

    // ...and the swap already pinned under the revoked verifier still settles:
    // Bob posts his side (EOA route) and Alice claims — no route call in claim
    _commitFor(BOB, lock, bob, alice);
    _warpToProposerClaim();
    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);
    _assertLockState(lock, LockState.Spent);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT), DEFAULT_AMOUNT);
    assertEq(BOB_RECIPIENT.balance, DEFAULT_AMOUNT);
  }

  function test_stateShape_termsHashAndPostedKeysUnchangedFromV1() public {
    // anchoring keeps V1 semantics: termsHash stores the canonical TERMS-ONLY
    // digest and posted is keyed by the bare terms digest — no identity is stored
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);

    assertEq(omnibus.termsHash(lock), omnibus.computeTermsHash(alice, bob));
    assertTrue(omnibus.posted(lock, omnibus.computeTermsDigest(alice)));
    assertFalse(omnibus.posted(lock, omnibus.computeTermsDigest(bob)));
  }
}
