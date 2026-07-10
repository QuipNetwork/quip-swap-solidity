// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {CommitAuth, IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {AuthHelper} from '../../utils/AuthHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';

/// @title Omnibus commit authorization Tests
/// @dev Signer-shape enforcement, verifier-activity gating, verifier result
/// handling, soft-guard semantics, and digest exactness for the CommitAuth
/// payload-authentication model. The ONLY accepted identity shape (see
/// Omnibus._enforceCommitAuthorized) is an ERC-7913 keyed signer:
/// verifier(20 bytes) ‖ key, with the verifier owner-activated; blobs of
/// 20 bytes or fewer (including bare addresses) are MalformedSigner
contract Omnibus_commitAuth is OmnibusTest {
  /// @dev commit alice's (native-asset) side as `sender` with explicit auth, inside
  /// the proposer window with the exact required value
  function _commitAliceSideAs(address sender, CommitAuth memory auth) internal {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(sender);
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob, auth);
  }

  /// @dev the same commit but expecting `revertData`; zero-length means "any revert"
  function _expectCommitAliceSideRevert(address sender, CommitAuth memory auth, bytes memory revertData) internal {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    vm.warp(AT_PROPOSER_COMMIT);
    if (revertData.length == 0) vm.expectRevert();
    else vm.expectRevert(revertData);
    vm.prank(sender);
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob, auth);
  }

  function _aliceDigestFor(bytes memory signer) internal view returns (bytes32) {
    return omnibus.commitDigest(lock, _aliceTerms(), _bobTerms(), keccak256(signer));
  }

  /// @dev baseline: verifierA rejects every verify call (returns wrong magic).
  /// Selector-prefix mock — matches ANY verify calldata
  function _mockVerifierRejectsAll() internal {
    vm.mockCall(
      address(verifierA),
      abi.encodeWithSelector(IERC7913SignatureVerifier.verify.selector),
      abi.encode(bytes4(0xffffffff))
    );
  }

  /// @dev verifierA accepts EXACTLY (key, digest, signature) and rejects all
  /// else: a reject-all prefix mock underneath, an exact-calldata accept on
  /// top (specific mocks take precedence; registered second wins either way)
  function _mockVerifierAcceptsOnly(bytes memory key, bytes32 digest, bytes memory signature) internal {
    _mockVerifierRejectsAll();
    vm.mockCall(
      address(verifierA),
      abi.encodeCall(IERC7913SignatureVerifier.verify, (key, digest, signature)),
      abi.encode(IERC7913SignatureVerifier.verify.selector)
    );
  }

  // ============ Malformed blobs (no address routes remain) ============

  function test_commitAuth_revertsWhen_signerEmpty() public {
    _expectCommitAliceSideRevert(
      ALICE, CommitAuth({signer: '', signature: ''}), abi.encodePacked(IOmnibus.MalformedSigner.selector)
    );
  }

  function test_commitAuth_revertsWhen_signerOneByte() public {
    _expectCommitAliceSideRevert(
      ALICE, CommitAuth({signer: hex'01', signature: ''}), abi.encodePacked(IOmnibus.MalformedSigner.selector)
    );
  }

  function test_commitAuth_revertsWhen_signerNineteenBytes() public {
    _expectCommitAliceSideRevert(
      ALICE, CommitAuth({signer: new bytes(19), signature: ''}), abi.encodePacked(IOmnibus.MalformedSigner.selector)
    );
  }

  function test_commitAuth_revertsWhen_signerIsBareAddress_evenWhenSender() public {
    // a 20-byte blob is a bare address: the self-auth shortcut is GONE, so even
    // msg.sender's own address is malformed — keyed identities only
    _expectCommitAliceSideRevert(
      ALICE,
      CommitAuth({signer: abi.encodePacked(ALICE), signature: ''}),
      abi.encodePacked(IOmnibus.MalformedSigner.selector)
    );
  }

  function test_commitAuth_revertsWhen_signerIsBareContractAddress() public {
    // has-code no longer routes anywhere (ERC-1271 removed): a contract's bare
    // 20-byte address is malformed like any other
    _expectCommitAliceSideRevert(
      CHARLIE,
      CommitAuth({signer: abi.encodePacked(address(verifierA)), signature: 'sig'}),
      abi.encodePacked(IOmnibus.MalformedSigner.selector)
    );
  }

  // ============ ERC-7913 keyed route ============

  function test_commitAuth_keyed_revertsWhen_verifierNotActive() public {
    bytes memory signer = abi.encodePacked(address(verifierB), bytes('alice-key'));
    _expectCommitAliceSideRevert(
      ALICE, CommitAuth({signer: signer, signature: ''}), abi.encodePacked(IOmnibus.VerifierNotActive.selector)
    );
  }

  function test_commitAuth_keyed_succeeds() public {
    // no mock needed: the one-function VerifierMock accepts everything
    _commitAliceSideAs(ALICE, AuthHelper.auth(aliceSigner));
    _assertLockState(lock, LockState.Free);
  }

  function test_commitAuth_keyed_succeedsOnExactDigest() public {
    // digest exactness: accept ONLY the raw-mirror digest (spec re-derivation);
    // the commit passes iff the enforced digest equals the mirror
    bytes32 mirror = _mirrorCommitDigest(lock, _aliceTerms(), _bobTerms(), aliceSigner);
    assertEq(mirror, _aliceDigestFor(aliceSigner), 'mirror must equal the commitDigest view');
    _mockVerifierAcceptsOnly(bytes('alice-key'), mirror, bytes('envelope'));

    _commitAliceSideAs(ALICE, CommitAuth({signer: aliceSigner, signature: bytes('envelope')}));
    _assertLockState(lock, LockState.Free);
  }

  function test_commitAuth_keyed_revertsWhen_digestNotAccepted() public {
    _mockVerifierAcceptsOnly(bytes('alice-key'), keccak256('some other digest'), bytes('envelope'));

    _expectCommitAliceSideRevert(
      ALICE,
      CommitAuth({signer: aliceSigner, signature: bytes('envelope')}),
      abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commitAuth_keyed_revertsWhen_verifierRejects() public {
    _mockVerifierRejectsAll();
    _expectCommitAliceSideRevert(
      ALICE, AuthHelper.auth(aliceSigner), abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commitAuth_keyed_revertsWhen_verifierReverts_bubbles() public {
    vm.mockCallRevert(
      address(verifierA),
      abi.encodeWithSelector(IERC7913SignatureVerifier.verify.selector),
      abi.encodeWithSignature('Error(string)', 'verifier reverted')
    );
    _expectCommitAliceSideRevert(
      ALICE, AuthHelper.auth(aliceSigner), abi.encodeWithSignature('Error(string)', 'verifier reverted')
    );
  }

  function test_commitAuth_keyed_revertsWhen_wrongMagicReturned() public {
    // a plausible-but-wrong selector must NOT be treated as valid
    vm.mockCall(
      address(verifierA),
      abi.encodeWithSelector(IERC7913SignatureVerifier.verify.selector),
      abi.encode(bytes4(0x12345678))
    );
    _expectCommitAliceSideRevert(
      ALICE, AuthHelper.auth(aliceSigner), abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commitAuth_keyed_relayedByAnySender() public {
    // Alice's keyed identity endorses; CHARLIE submits and FUNDS (sender pays,
    // identity authorizes)
    _commitAliceSideAs(CHARLIE, AuthHelper.auth(aliceSigner));
    _assertLockState(lock, LockState.Free);
  }

  // ============ Digest exactness: tampered context is rejected ============

  /// @dev verifierA accepts EXACTLY the digest for (lock, party, counterparty,
  /// aliceSigner); any on-chain tampering with that context recomputes a
  /// different digest, falls through to the reject baseline, and fails
  function _authAcceptedOnlyFor(
    bytes32 _lock,
    Terms memory party,
    Terms memory cp
  ) internal returns (CommitAuth memory) {
    _mockVerifierAcceptsOnly(bytes('alice-key'), _mirrorCommitDigest(_lock, party, cp, aliceSigner), bytes('envelope'));
    return CommitAuth({signer: aliceSigner, signature: bytes('envelope')});
  }

  function _expectTamperedCommitRejected(
    CommitAuth memory auth,
    bytes32 _lock,
    Terms memory party,
    Terms memory cp
  ) internal {
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.InvalidCommitSignature.selector);
    vm.prank(CHARLIE);
    omnibus.commit{value: _totalNativeForCommit(party)}(_lock, party, cp, auth);
  }

  function test_commitAuth_digest_revertsWhen_lockTampered() public {
    CommitAuth memory auth = _authAcceptedOnlyFor(lock, _aliceTerms(), _bobTerms());
    bytes32 otherLock = omnibus.exposed_generateLock(keccak256('other-secret'));
    _expectTamperedCommitRejected(auth, otherLock, _aliceTerms(), _bobTerms());
  }

  function test_commitAuth_digest_revertsWhen_partyTermsTampered() public {
    CommitAuth memory auth = _authAcceptedOnlyFor(lock, _aliceTerms(), _bobTerms());
    Terms memory tampered = _aliceTermsOn(block.chainid, _makeNativeAssets(DEFAULT_AMOUNT + 1));
    _expectTamperedCommitRejected(auth, lock, tampered, _bobTerms());
  }

  function test_commitAuth_digest_revertsWhen_counterpartyTermsTampered() public {
    CommitAuth memory auth = _authAcceptedOnlyFor(lock, _aliceTerms(), _bobTerms());
    Terms memory tampered = _bobTermsOn(block.chainid, _makeERC20Assets(DEFAULT_AMOUNT + 1));
    _expectTamperedCommitRejected(auth, lock, _aliceTerms(), tampered);
  }

  function test_commitAuth_digest_revertsWhen_signerHashTampered() public {
    // envelope valid for the digest bound to ALICE's blob, but the declared blob
    // is swapped to another keyed identity: signerHash binding must reject the
    // transplant (the on-chain digest is recomputed from the DECLARED blob)
    bytes memory swappedSigner = abi.encodePacked(address(verifierA), bytes('other-key'));
    _mockVerifierAcceptsOnly(bytes('other-key'), _aliceDigestFor(aliceSigner), bytes('envelope'));

    _expectCommitAliceSideRevert(
      CHARLIE,
      CommitAuth({signer: swappedSigner, signature: bytes('envelope')}),
      abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commitAuth_digest_revertsWhen_chainIdTampered() public {
    // an envelope endorsed for THIS chain's digest must not validate against
    // chain-999 context (the replay scope is the baked DOMAIN_SEPARATOR —
    // per-chain deployments bake different separators). Terms must move with
    // the chain (enforceChainId), so rebuild them on the new id: their digests
    // change and the envelope was never accepted for that context
    CommitAuth memory auth = _authAcceptedOnlyFor(lock, _aliceTerms(), _bobTerms());

    uint256 newChainId = 999;
    vm.chainId(newChainId);
    Terms memory aliceOn999 = _aliceTermsOn(newChainId, _makeNativeAssets(DEFAULT_AMOUNT));
    Terms memory bobOn999 = _bobTermsOn(newChainId, _makeERC20Assets(DEFAULT_AMOUNT));

    _expectTamperedCommitRejected(auth, lock, aliceOn999, bobOn999);
  }

  // ============ Soft-guard semantics (a decision, not an accident) ============

  function test_commitAuth_softGuard_thirdPartyPostsOtherSideWithOwnIdentityAndFunds() public {
    // Alice posts her side (keyed). A THIRD PARTY (Charlie) then posts BOB's side
    // with his OWN keyed identity and OWN funds: the contract never enforces WHICH
    // identity posts a side — economically a donation, since recipients are
    // terms-pinned and claim stays secret-gated
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    _commitFor(ALICE, lock, alice, bob);
    _assertLockState(lock, LockState.Free);

    uint256 charlieErc20Before = mockERC20.balanceOf(CHARLIE);
    uint256 bobErc20Before = mockERC20.balanceOf(BOB);
    uint256 omnibusErc20Before = mockERC20.balanceOf(address(omnibus));

    vm.warp(AT_TAKER_COMMIT);
    vm.prank(CHARLIE);
    omnibus.commit{value: 0}(lock, bob, alice, AuthHelper.keyedAuth(address(verifierA), CHARLIE));
    _assertLockState(lock, LockState.Committed);

    // the SENDER funded the leg; the side's named party paid nothing
    assertEq(charlieErc20Before - mockERC20.balanceOf(CHARLIE), DEFAULT_AMOUNT);
    assertEq(mockERC20.balanceOf(BOB), bobErc20Before);
    assertEq(mockERC20.balanceOf(address(omnibus)) - omnibusErc20Before, DEFAULT_AMOUNT);

    // the swap still settles to the TERMS-pinned recipients
    _warpToProposerClaim();
    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);
    _assertLockState(lock, LockState.Spent);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT), DEFAULT_AMOUNT);
    assertEq(BOB_RECIPIENT.balance, DEFAULT_AMOUNT);
  }

  function test_commitAuth_fundingModel_arbitrarySenderFundsKeyedIdentityLeg() public {
    // an arbitrary unrelated EOA sender submits a commit carrying Alice's KEYED
    // identity: succeeds, and the SENDER (not the identity) funds the leg + fee
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    address relayer = makeAddr('relayer');
    uint256 fee = 0.005 ether;
    omnibus.setCommitmentFee(fee);
    uint256 required = _totalNativeForCommit(alice) + fee;
    vm.deal(relayer, required);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(relayer);
    omnibus.commit{value: required}(lock, alice, bob, AuthHelper.auth(aliceSigner));

    _assertLockState(lock, LockState.Free);
    assertEq(relayer.balance, 0); // relayer paid everything
    assertEq(omnibus.accruedFees(), fee);
  }
}
