// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {CommitAuth, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {ShrincsCodec} from '@quip.network/hashsigs-solidity-0.2.0/contracts/ShrincsCodec.sol';
import {ShrincsTypes} from '@quip.network/hashsigs-solidity-0.2.0/contracts/ShrincsTypes.sol';
import {ShrincsVerifier} from '@quip.network/hashsigs-solidity-0.2.0/contracts/ShrincsVerifier.sol';
import {ShrincsTestSigner} from '@quip.network/hashsigs-solidity-0.2.0/test/helpers/ShrincsTestSigner.sol';

/// @title Omnibus × real ShrincsVerifier integration
/// @dev End-to-end keyed route with the REAL stateful SHRINCS verifier only:
/// each side has its own real SHRINCS identity, signs its actual commit digest
/// at an explicit leaf, and the envelope goes through ShrincsCodec.
/// This suite only tests the happy path — by intention; all other
/// verifier-reliant tests are covered in behaviors/commitAuth.t.sol
contract Omnibus_ShrincsVerifierIntegration is OmnibusTest {
  ShrincsVerifier internal shrincs;
  ShrincsTypes.SigningKey internal aliceKey;
  ShrincsTypes.PublicKey internal alicePub;
  bytes internal aliceKeyedSigner; // verifier(20) ‖ 32-byte publicKeyCommitment
  ShrincsTypes.SigningKey internal bobKey;
  ShrincsTypes.PublicKey internal bobPub;
  bytes internal bobKeyedSigner;

  function setUp() public override {
    super.setUp();

    shrincs = new ShrincsVerifier();
    omnibus.setVerifierActivity(address(shrincs), true);

    (aliceKey, alicePub, aliceKeyedSigner) = _realIdentity(bytes('quip-swap omnibus integration seed: alice'));
    (bobKey, bobPub, bobKeyedSigner) = _realIdentity(bytes('quip-swap omnibus integration seed: bob'));
  }

  /// @dev keygen a real SHRINCS identity; the ERC-7913 key is the 32-byte
  /// bundle commitment word
  function _realIdentity(bytes memory seed)
    internal
    view
    returns (ShrincsTypes.SigningKey memory sk, ShrincsTypes.PublicKey memory pk, bytes memory signer)
  {
    bool ok;
    (sk, pk, ok) = ShrincsTestSigner.keygen(seed, 4);
    assertTrue(ok, 'keygen must succeed');
    bytes memory commitmentBytes = pk.publicKeyCommitment;
    bytes32 word;
    assembly {
      word := mload(add(commitmentBytes, 32))
    }
    signer = abi.encodePacked(address(shrincs), word);
  }

  function _signStatefulEnvelope(
    ShrincsTypes.SigningKey memory sk,
    ShrincsTypes.PublicKey memory pk,
    bytes32 digest,
    uint32 leafIndex
  ) internal view returns (bytes memory) {
    (ShrincsTypes.StatefulSignature memory sig, bool ok) =
      ShrincsTestSigner.signStatefulRawAtLeaf(sk, leafIndex, abi.encodePacked(digest));
    require(ok, 'stateful signing must succeed');
    return ShrincsCodec.encodeStatefulEnvelope(pk, sig);
  }

  function test_integration_bothCommitsRealKeyed_claim() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // 1. Alice: her real identity signs HER commit digest at explicit leaf 1
    bytes32 aliceDigest = omnibus.commitDigest(lock, alice, bob, keccak256(aliceKeyedSigner));
    CommitAuth memory aliceAuth =
      CommitAuth({signer: aliceKeyedSigner, signature: _signStatefulEnvelope(aliceKey, alicePub, aliceDigest, 1)});

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob, aliceAuth);
    _assertLockState(lock, LockState.Free);

    // 2. Bob: his OWN real identity signs HIS commit digest (sides swap roles)
    bytes32 bobDigest = omnibus.commitDigest(lock, bob, alice, keccak256(bobKeyedSigner));
    CommitAuth memory bobAuth =
      CommitAuth({signer: bobKeyedSigner, signature: _signStatefulEnvelope(bobKey, bobPub, bobDigest, 1)});

    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bob, alice, bobAuth);
    _assertLockState(lock, LockState.Committed);

    // 3. claim settles to terms-pinned recipients
    _warpToProposerClaim();
    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);
    _assertLockState(lock, LockState.Spent);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT), DEFAULT_AMOUNT);
    assertEq(BOB_RECIPIENT.balance, DEFAULT_AMOUNT);
  }

  function test_integration_keyedCommit_rejectsWrongDigestSignature() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // sign a DIFFERENT digest; the real verifier must reject it for the commit digest
    bytes memory wrongEnvelope = _signStatefulEnvelope(aliceKey, alicePub, keccak256('some other payload'), 1);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(); // InvalidCommitSignature (verifier returns 0xffffffff)
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, CommitAuth({signer: aliceKeyedSigner, signature: wrongEnvelope})
    );
  }
}
