// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {CommitAuth, IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {AuthHelper} from '../../utils/AuthHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {SHRINCS} from '@quip.network/hashsigs-solidity-0.2.0/contracts/SHRINCS.sol';
import {SHRINCSVerifier} from '@quip.network/hashsigs-solidity-0.2.0/contracts/SHRINCSVerifier.sol';
import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';
import {SHRINCSTestSigner} from '@quip.network/hashsigs-solidity-0.2.0/test/helpers/SHRINCSTestSigner.sol';

/// @dev minimal concrete instance of the abstract profile base (mirrors the
/// dependency's own test harness): the stateful verify/attest paths are
/// profile-agnostic and never read the pinned SPHINCSPlusC address
contract ShrincsIntegrationVerifier is SHRINCSVerifier {
  function _pinnedSphincsPlusC() internal pure override returns (address) {
    return address(0);
  }
}

/// @dev minimal stand-in for a PQ smart wallet on the attested route: the two
/// calls the real wallet makes in ONE transaction — verifyAndAttest of its
/// single envelope signature, then the downstream commit from the SAME address
/// (wasVerified binds account == msg.sender at both ends). Split entrypoints so
/// tests can also place the calls in DIFFERENT transactions
contract WalletStub {
  receive() external payable {}

  function attest(
    SHRINCSVerifier verifier,
    bytes calldata key,
    bytes32 envelopeHash,
    bytes calldata envelope
  ) external {
    require(
      verifier.verifyAndAttest(key, envelopeHash, envelope) == IERC7913SignatureVerifier.verify.selector,
      'attesting verification must succeed'
    );
  }

  function commitAs(
    IOmnibus omnibus,
    uint256 value,
    bytes32 lock,
    Terms calldata party,
    Terms calldata counterparty,
    CommitAuth calldata auth
  ) external {
    omnibus.commit{value: value}(lock, party, counterparty, auth);
  }
}

/// @title Omnibus × real SHRINCSVerifier integration
/// @dev End-to-end commit routes with the REAL stateful SHRINCS verifier only:
/// each side has its own real SHRINCS identity, signs at an explicit leaf, and
/// the envelope goes through SHRINCS.encodeStatefulEnvelope.
/// This suite only tests the happy paths plus one rejection per route — by
/// intention; all other verifier-reliant tests are covered in
/// behaviors/commit.t.sol and behaviors/_enforceCommitAuth.t.sol
contract Omnibus_ShrincsVerifierIntegration is OmnibusTest {
  ShrincsIntegrationVerifier internal shrincs;
  SHRINCS.SigningKey internal aliceKey;
  SHRINCS.PublicKey internal alicePub;
  bytes internal aliceKey32; // the raw 32-byte ERC-7913 key (publicKeyCommitment word)
  bytes internal aliceKeyedSigner; // verifier(20) ‖ 32-byte publicKeyCommitment
  SHRINCS.SigningKey internal bobKey;
  SHRINCS.PublicKey internal bobPub;
  bytes internal bobKey32;
  bytes internal bobKeyedSigner;

  WalletStub internal wallet;
  bytes32 internal constant WALLET_BINDING = keccak256('wallet execution commitment');
  // envelope attested in setUp — a PREVIOUS transaction from every test's view
  // (Foundry runs setUp and each test as separate transactions), so EIP-1153
  // must have cleared it by the time a test runs
  bytes32 internal setUpEnvelopeHash;

  function setUp() public override {
    super.setUp();

    shrincs = new ShrincsIntegrationVerifier();
    omnibus.setVerifierActivity(address(shrincs), true);

    (aliceKey, alicePub, aliceKey32, aliceKeyedSigner) =
      _realIdentity(bytes('quip-swap omnibus integration seed: alice'));
    (bobKey, bobPub, bobKey32, bobKeyedSigner) = _realIdentity(bytes('quip-swap omnibus integration seed: bob'));

    wallet = new WalletStub();
    vm.deal(address(wallet), 10 ether);

    // attest alice's real envelope NOW (leaf 2; leaf 1 stays for in-test
    // signatures) so the tx-boundary test can prove the attestation is gone
    setUpEnvelopeHash = _envelopeHash(
      WALLET_BINDING, omnibus.commitDigest(lock, _aliceTerms(), _bobTerms(), keccak256(aliceKeyedSigner))
    );
    wallet.attest(
      shrincs, aliceKey32, setUpEnvelopeHash, _signStatefulEnvelope(aliceKey, alicePub, setUpEnvelopeHash, 2)
    );
  }

  /// @dev keygen a real SHRINCS identity; the ERC-7913 key is the 32-byte
  /// bundle commitment word
  function _realIdentity(bytes memory seed)
    internal
    view
    returns (SHRINCS.SigningKey memory sk, SHRINCS.PublicKey memory pk, bytes memory key32, bytes memory signer)
  {
    bool ok;
    (sk, pk, ok) = SHRINCSTestSigner.keygen(seed, 4);
    assertTrue(ok, 'keygen must succeed');
    bytes memory commitmentBytes = pk.publicKeyCommitment;
    bytes32 word;
    assembly {
      word := mload(add(commitmentBytes, 32))
    }
    key32 = abi.encodePacked(word);
    signer = abi.encodePacked(address(shrincs), word);
  }

  /// @dev sign exactly the 32 packed bytes of `digest` at an explicit leaf
  function _signStatefulEnvelope(
    SHRINCS.SigningKey memory sk,
    SHRINCS.PublicKey memory pk,
    bytes32 digest,
    uint32 leafIndex
  ) internal view returns (bytes memory) {
    (SHRINCS.Signature memory sig, bool ok) =
      SHRINCSTestSigner.signStatefulRawAtLeaf(sk, leafIndex, abi.encodePacked(digest));
    require(ok, 'stateful signing must succeed');
    return SHRINCS.encodeStatefulEnvelope(pk, sig);
  }

  /// @dev the attested route's composite envelope hash — spec re-derivation
  function _envelopeHash(bytes32 walletBinding, bytes32 commitDigest) internal view returns (bytes32) {
    return keccak256(abi.encode(omnibus.ENVELOPE_TYPEHASH(), walletBinding, commitDigest));
  }

  // ============ Keyed route (signature over commitDigest) ============

  function test_integration_bothCommitsRealKeyed_claim() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // 1. Alice: her real identity signs HER commit digest at explicit leaf 1
    bytes32 aliceDigest = omnibus.commitDigest(lock, alice, bob, keccak256(aliceKeyedSigner));
    CommitAuth memory aliceAuth = CommitAuth({
      signer: aliceKeyedSigner,
      signature: _signStatefulEnvelope(aliceKey, alicePub, aliceDigest, 1),
      walletBinding: bytes32(0)
    });

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob, aliceAuth);
    _assertLockState(lock, LockState.Free);

    // 2. Bob: his OWN real identity signs HIS commit digest (sides swap roles)
    bytes32 bobDigest = omnibus.commitDigest(lock, bob, alice, keccak256(bobKeyedSigner));
    CommitAuth memory bobAuth = CommitAuth({
      signer: bobKeyedSigner, signature: _signStatefulEnvelope(bobKey, bobPub, bobDigest, 1), walletBinding: bytes32(0)
    });

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
    vm.expectRevert(IOmnibus.InvalidCommitSignature.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, CommitAuth({signer: aliceKeyedSigner, signature: wrongEnvelope, walletBinding: bytes32(0)})
    );
  }

  // ============ Attested route (one leaf covers wallet execution + commit) ============

  function test_integration_attestedCommit_singleLeaf_claim() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Alice's identity signs the ONE composite envelope: the wallet's own
    // execution commitment (opaque here) ‖ her commit digest — a single leaf
    // for both. The wallet attests and commits in THIS transaction; it is the
    // committing sender because wasVerified binds account == msg.sender
    bytes32 aliceDigest = omnibus.commitDigest(lock, alice, bob, keccak256(aliceKeyedSigner));
    bytes32 envelopeHash = _envelopeHash(WALLET_BINDING, aliceDigest);
    bytes memory envelope = _signStatefulEnvelope(aliceKey, alicePub, envelopeHash, 1);

    vm.warp(AT_PROPOSER_COMMIT);
    wallet.attest(shrincs, aliceKey32, envelopeHash, envelope);
    wallet.commitAs(
      omnibus, _totalNativeForCommit(alice), lock, alice, bob, AuthHelper.attestedAuth(aliceKeyedSigner, WALLET_BINDING)
    );
    _assertLockState(lock, LockState.Free);

    // Bob completes keyed; the swap settles exactly like the all-keyed flow
    bytes32 bobDigest = omnibus.commitDigest(lock, bob, alice, keccak256(bobKeyedSigner));
    CommitAuth memory bobAuth = CommitAuth({
      signer: bobKeyedSigner, signature: _signStatefulEnvelope(bobKey, bobPub, bobDigest, 1), walletBinding: bytes32(0)
    });
    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bob, alice, bobAuth);
    _assertLockState(lock, LockState.Committed);

    _warpToProposerClaim();
    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);
    _assertLockState(lock, LockState.Spent);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT), DEFAULT_AMOUNT);
    assertEq(BOB_RECIPIENT.balance, DEFAULT_AMOUNT);
  }

  function test_integration_attestedCommit_rejectsWithoutAttestation() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // a hostile caller merely CLAIMS the route: no verifyAndAttest happened for
    // THIS account this transaction, so the real verifier holds no matching
    // (account, keyHash, hash) triple
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.AttestationNotFound.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, AuthHelper.attestedAuth(aliceKeyedSigner, WALLET_BINDING)
    );
  }

  function test_integration_attestedCommit_rejectsAttestationFromPreviousTransaction() public {
    // setUp verified-and-attested alice's REAL envelope, but setUp is a
    // previous transaction: EIP-1153 cleared the registry, so the exact same
    // wallet presenting the exact same auth must miss
    assertFalse(
      shrincs.wasVerified(address(wallet), keccak256(aliceKey32), setUpEnvelopeHash),
      'transient attestation must not survive the transaction boundary'
    );

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.AttestationNotFound.selector);
    wallet.commitAs(
      omnibus, _totalNativeForCommit(alice), lock, alice, bob, AuthHelper.attestedAuth(aliceKeyedSigner, WALLET_BINDING)
    );
  }
}
