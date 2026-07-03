// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {CommitAuth, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {ShrincsCodec} from '@quip.network/hashsigs-solidity-0.2.0/contracts/ShrincsCodec.sol';
import {ShrincsTypes} from '@quip.network/hashsigs-solidity-0.2.0/contracts/ShrincsTypes.sol';
import {ShrincsVerifier} from '@quip.network/hashsigs-solidity-0.2.0/contracts/ShrincsVerifier.sol';
import {ShrincsTestSigner} from '@quip.network/hashsigs-solidity-0.2.0/test/helpers/ShrincsTestSigner.sol';
import {console} from 'forge-std-1.14.0/console.sol';

/// @title Omnibus × real ShrincsVerifier integration
/// @dev End-to-end keyed route with the REAL stateful SHRINCS verifier (no mock):
/// Alice's keyed identity signs the actual commit digest at an explicit leaf, the
/// envelope goes through ShrincsCodec, Bob posts his side EOA-self-auth, Alice
/// claims. Also records gas per route (the stateful verify is the expensive one)
contract Omnibus_ShrincsVerifierIntegration is OmnibusTest {
  ShrincsVerifier internal shrincs;
  ShrincsTypes.SigningKey internal signingKey;
  ShrincsTypes.PublicKey internal publicKey;
  bytes32 internal commitment;
  bytes internal keyedSigner; // verifier(20) ‖ 32-byte publicKeyCommitment

  function setUp() public override {
    super.setUp();

    shrincs = new ShrincsVerifier();
    omnibus.setVerifierTrust(address(shrincs), true);

    (ShrincsTypes.SigningKey memory sk, ShrincsTypes.PublicKey memory pk, bool ok) =
      ShrincsTestSigner.keygen(bytes('quip-swap omnibus integration seed'), 4);
    assertTrue(ok, 'keygen must succeed');
    signingKey = sk;
    publicKey = pk;

    // the ERC-7913 key is the 32-byte bundle commitment word
    bytes memory commitmentBytes = pk.publicKeyCommitment;
    bytes32 word;
    assembly {
      word := mload(add(commitmentBytes, 32))
    }
    commitment = word;
    keyedSigner = abi.encodePacked(address(shrincs), commitment);
  }

  function _signStatefulEnvelope(bytes32 digest, uint32 leafIndex) internal view returns (bytes memory) {
    (ShrincsTypes.StatefulSignature memory sig, bool ok) =
      ShrincsTestSigner.signStatefulRawAtLeaf(signingKey, leafIndex, abi.encodePacked(digest));
    require(ok, 'stateful signing must succeed');
    return ShrincsCodec.encodeStatefulEnvelope(publicKey, sig);
  }

  function test_integration_keyedCommit_eoaCommit_claim() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // 1. keyed Alice: sign the REAL commit digest at explicit leaf 1
    bytes32 digest = omnibus.commitDigest(lock, alice, bob, keccak256(keyedSigner));
    CommitAuth memory keyedAuth = CommitAuth({signer: keyedSigner, signature: _signStatefulEnvelope(digest, 1)});

    vm.warp(AT_PROPOSER_COMMIT);
    uint256 gasBefore = gasleft();
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob, keyedAuth);
    console.log('gas: keyed commit (real stateful SHRINCS verify):', gasBefore - gasleft());
    _assertLockState(lock, LockState.Free);

    // 2. EOA Bob, self-auth
    vm.warp(AT_TAKER_COMMIT);
    gasBefore = gasleft();
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bob, alice, _selfAuth(BOB));
    console.log('gas: self-auth commit:', gasBefore - gasleft());
    _assertLockState(lock, LockState.Committed);

    // 3. claim settles to terms-pinned recipients
    _warpToProposerClaim();
    gasBefore = gasleft();
    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);
    console.log('gas: claim:', gasBefore - gasleft());
    _assertLockState(lock, LockState.Spent);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT), DEFAULT_AMOUNT);
    assertEq(BOB_RECIPIENT.balance, DEFAULT_AMOUNT);
  }

  function test_integration_keyedCommit_rejectsWrongDigestSignature() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // sign a DIFFERENT digest; the real verifier must reject it for the commit digest
    bytes memory wrongEnvelope = _signStatefulEnvelope(keccak256('some other payload'), 1);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(); // InvalidCommitSignature (verifier returns 0xffffffff)
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, CommitAuth({signer: keyedSigner, signature: wrongEnvelope})
    );
  }

  function test_integration_verifierIsMathOracle_leafReuseNotBurnedOnChain() public {
    // recorded on-chain fact (plan A6/Rev 8): verification consumes no state — the
    // SAME leaf validates two different commits; leaf hygiene is the keyholder's concern
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    bytes32 digest1 = omnibus.commitDigest(lock, alice, bob, keccak256(keyedSigner));

    bytes32 otherLock = omnibus.exposed_generateLock(keccak256('second-secret'));
    bytes32 digest2 = omnibus.commitDigest(otherLock, alice, bob, keccak256(keyedSigner));

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, CommitAuth({signer: keyedSigner, signature: _signStatefulEnvelope(digest1, 1)})
    );
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      otherLock, alice, bob, CommitAuth({signer: keyedSigner, signature: _signStatefulEnvelope(digest2, 1)})
    );

    _assertLockState(lock, LockState.Free);
    _assertLockState(otherLock, LockState.Free);
  }
}
