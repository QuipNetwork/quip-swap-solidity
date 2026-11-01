// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {CommitAuth, IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {AuthHelper} from '../../utils/AuthHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {SHRINCS} from '@quip.network/hashsigs-solidity-0.3.0/contracts/SHRINCS.sol';
import {SHRINCSVerifier} from '@quip.network/hashsigs-solidity-0.3.0/contracts/SHRINCSVerifier.sol';
import {SHRINCSTestCodec} from '@quip.network/hashsigs-solidity-0.3.0/test/helpers/SHRINCSTestCodec.sol';
import {SHRINCSTestSigner} from '@quip.network/hashsigs-solidity-0.3.0/test/helpers/SHRINCSTestSigner.sol';

/// @dev minimal concrete instance of the abstract profile base (mirrors the
/// dependency's own test harness): the stateful verify path is
/// profile-agnostic and never reads the pinned SPHINCSPlusC address
contract ShrincsIntegrationVerifier is SHRINCSVerifier {
  function _pinnedSphincsPlusC() internal pure override returns (address) {
    return address(0);
  }
}

/// @dev minimal stand-in for a PQ smart wallet on the wallet route: the one
/// call the real wallet makes is the downstream commit from its own address —
/// the route authorizes on factory membership of msg.sender, so the stub only
/// needs to BE the sender (its registration is the test's setup concern)
contract WalletStub {
  receive() external payable {}

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
/// each side has its own real SHRINCS identity and signs at an explicit leaf.
/// This suite only tests the happy paths plus one rejection per route — by
/// intention; all other tests are covered in behaviors/commit.t.sol and
/// behaviors/_enforceCommitAuth.t.sol
contract Omnibus_ShrincsVerifierIntegration is OmnibusTest {
  ShrincsIntegrationVerifier internal shrincs;
  SHRINCS.SigningKey internal aliceKey;
  SHRINCS.PublicKey internal alicePub;
  bytes internal aliceKeyedSigner; // verifier(20) ‖ 32-byte publicKeyCommitment
  SHRINCS.SigningKey internal bobKey;
  SHRINCS.PublicKey internal bobPub;
  bytes internal bobKeyedSigner;

  WalletStub internal wallet;

  function setUp() public override {
    super.setUp();

    shrincs = new ShrincsIntegrationVerifier();
    omnibus.setVerifierActivity(address(shrincs), true);

    (aliceKey, alicePub, aliceKeyedSigner) = _realIdentity(bytes('quip-swap omnibus integration seed: alice'));
    (bobKey, bobPub, bobKeyedSigner) = _realIdentity(bytes('quip-swap omnibus integration seed: bob'));

    // register the stub as a factory-deployed quip wallet (write-once registry
    // membership is the wallet route's whole authorization)
    wallet = new WalletStub();
    vm.deal(address(wallet), 10 ether);
    _registerWallet(address(wallet));
  }

  /// @dev keygen a real SHRINCS identity; the ERC-7913 key is the 32-byte
  /// bundle commitment word
  function _realIdentity(bytes memory seed)
    internal
    view
    returns (SHRINCS.SigningKey memory sk, SHRINCS.PublicKey memory pk, bytes memory signer)
  {
    bool ok;
    (sk, pk, ok) = SHRINCSTestSigner.keygen(seed, 4);
    assertTrue(ok, 'keygen must succeed');
    bytes memory commitmentBytes = pk.publicKeyCommitment;
    bytes32 word;
    assembly {
      word := mload(add(commitmentBytes, 32))
    }
    signer = abi.encodePacked(address(shrincs), word);
  }

  /// @dev sign the commitment-bound message hash of `digest` at an explicit leaf
  function _signStatefulEnvelope(
    SHRINCS.SigningKey memory sk,
    SHRINCS.PublicKey memory pk,
    bytes32 digest,
    uint32 leafIndex
  ) internal view returns (bytes memory) {
    bytes memory commitmentBytes = pk.publicKeyCommitment;
    bytes32 commitment;
    assembly {
      commitment := mload(add(commitmentBytes, 32))
    }
    (SHRINCS.Signature memory sig, bool ok) = SHRINCSTestSigner.signStatefulRawAtLeaf(
      sk, leafIndex, abi.encodePacked(SHRINCS.statefulRawMessageHash(commitment, digest))
    );
    require(ok, 'stateful signing must succeed');
    return SHRINCSTestCodec.encodeStatefulEnvelope(pk, sig);
  }

  // ============ Keyed route (signature over commitDigest) ============

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
    _assertSwapState(lock, alice, bob, LockState.Free);

    // 2. Bob: his OWN real identity signs HIS commit digest (sides swap roles)
    bytes32 bobDigest = omnibus.commitDigest(lock, bob, alice, keccak256(bobKeyedSigner));
    CommitAuth memory bobAuth =
      CommitAuth({signer: bobKeyedSigner, signature: _signStatefulEnvelope(bobKey, bobPub, bobDigest, 1)});

    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bob, alice, bobAuth);
    _assertSwapState(lock, alice, bob, LockState.Committed);

    // 3. claim settles to terms-pinned recipients
    _warpToProposerClaim();
    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);
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
      lock, alice, bob, CommitAuth({signer: aliceKeyedSigner, signature: wrongEnvelope})
    );
  }

  // ============ Wallet route (factory membership, no signature) ============

  function test_integration_walletCommit_claim() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // the registered wallet commits Alice's side with NO signature; her real
    // SHRINCS identity rides along as attribution only
    vm.warp(AT_PROPOSER_COMMIT);
    wallet.commitAs(omnibus, _totalNativeForCommit(alice), lock, alice, bob, AuthHelper.walletAuth(aliceKeyedSigner));
    _assertSwapState(lock, alice, bob, LockState.Free);

    // Bob completes keyed; the swap settles exactly like the all-keyed flow
    bytes32 bobDigest = omnibus.commitDigest(lock, bob, alice, keccak256(bobKeyedSigner));
    CommitAuth memory bobAuth =
      CommitAuth({signer: bobKeyedSigner, signature: _signStatefulEnvelope(bobKey, bobPub, bobDigest, 1)});
    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bob, alice, bobAuth);
    _assertSwapState(lock, alice, bob, LockState.Committed);

    _warpToProposerClaim();
    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT), DEFAULT_AMOUNT);
    assertEq(BOB_RECIPIENT.balance, DEFAULT_AMOUNT);
  }

  function test_integration_walletCommit_rejectsUnregisteredSender() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // a hostile caller merely CLAIMS the route: ALICE's EOA is not a
    // factory-deployed wallet, so membership fails regardless of the (real)
    // identity blob she declares
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.NotQuipWallet.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob, AuthHelper.walletAuth(aliceKeyedSigner));
  }
}
