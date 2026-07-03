// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {CommitAuth, IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {Erc1271Mock} from '../../mocks/Erc1271Mock.sol';
import {VerifierMock} from '../../mocks/VerifierMock.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus commit authorization Tests
/// @dev Routing matrix, soft-guard semantics, and digest exactness for the
/// CommitAuth payload-authentication model. Routing (see Omnibus._enforceCommitAuthorized):
/// blob < 20 bytes → MalformedSigner; == 20 → self-auth / EOA ecrecover / ERC-1271 by
/// code presence; > 20 → owner-allowlisted ERC-7913 verifier(20) ‖ key
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

  // ============ Malformed blobs ============

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

  // ============ Self-auth route ============

  function test_commitAuth_selfAuth_succeedsWithEmptySignature() public {
    _commitAliceSideAs(ALICE, _selfAuth(ALICE));
    _assertLockState(lock, LockState.Free);
  }

  function test_commitAuth_selfAuth_revertsWhen_relayedWithEmptySignature() public {
    // CHARLIE relays a commit declaring ALICE's identity with no signature: the
    // self-auth shortcut requires msg.sender == identity, and ALICE (a codeless
    // makeAddr account) then routes as an EOA, which rejects the empty signature
    _expectCommitAliceSideRevert(CHARLIE, _selfAuth(ALICE), abi.encodePacked(IOmnibus.InvalidCommitSignature.selector));
  }

  // ============ EOA (detached ECDSA) route ============

  function test_commitAuth_eoa_validSignature_relayedByAnySender() public {
    // Bob's identity signs; CHARLIE submits and FUNDS (sender pays, identity authorizes)
    CommitAuth memory auth = _eoaAuth(BOB_PK, lock, _aliceTerms(), _bobTerms());
    _commitAliceSideAs(CHARLIE, auth);
    _assertLockState(lock, LockState.Free);
  }

  function test_commitAuth_eoa_revertsWhen_signedByWrongKey() public {
    uint256 otherPk = uint256(keccak256('not-bob'));
    bytes32 digest = _aliceDigestFor(bobSigner);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherPk, digest);

    _expectCommitAliceSideRevert(
      CHARLIE,
      CommitAuth({signer: bobSigner, signature: abi.encodePacked(r, s, v)}),
      abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commitAuth_eoa_revertsWhen_highSSignature() public {
    bytes32 digest = _aliceDigestFor(bobSigner);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOB_PK, digest);
    // malleate into the upper half-order form; OZ ECDSA rejects high-s
    uint256 secp256k1nOrder = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    bytes32 highS = bytes32(secp256k1nOrder - uint256(s));
    uint8 flippedV = v == 27 ? 28 : 27;

    _expectCommitAliceSideRevert(
      CHARLIE,
      CommitAuth({signer: bobSigner, signature: abi.encodePacked(r, highS, flippedV)}),
      abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commitAuth_eoa_revertsWhen_emptySignature() public {
    _expectCommitAliceSideRevert(
      CHARLIE,
      CommitAuth({signer: bobSigner, signature: ''}),
      abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  // ============ ERC-1271 (has-code) route ============

  function test_commitAuth_erc1271_accept_succeeds() public {
    erc1271.setMode(Erc1271Mock.Mode.Accept);
    _commitAliceSideAs(CHARLIE, CommitAuth({signer: abi.encodePacked(address(erc1271)), signature: 'sig'}));
    _assertLockState(lock, LockState.Free);
  }

  function test_commitAuth_erc1271_revertsWhen_wrongMagic() public {
    erc1271.setMode(Erc1271Mock.Mode.WrongMagic);
    _expectCommitAliceSideRevert(
      CHARLIE,
      CommitAuth({signer: abi.encodePacked(address(erc1271)), signature: 'sig'}),
      abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commitAuth_erc1271_revertsWhen_signerReverts() public {
    erc1271.setMode(Erc1271Mock.Mode.Revert);
    _expectCommitAliceSideRevert(
      CHARLIE,
      CommitAuth({signer: abi.encodePacked(address(erc1271)), signature: 'sig'}),
      abi.encodeWithSignature('Error(string)', 'Erc1271Mock: revert mode')
    );
  }

  function test_commitAuth_erc1271_isStaticcall_writeAttemptReverts() public {
    // proves the router reaches 1271 by STATICCALL: the mock's write attempt
    // reverts inside the static context instead of recording state
    erc1271.setMode(Erc1271Mock.Mode.AttemptWrite);
    _expectCommitAliceSideRevert(
      CHARLIE, CommitAuth({signer: abi.encodePacked(address(erc1271)), signature: 'sig'}), ''
    );
    assertEq(erc1271.writes(), 0);
  }

  // ============ EIP-7702 behavior (documented as a test; raw-key support deferred) ============

  function test_commitAuth_delegatedEoa_rawEcdsaRejected_routesTo1271() public {
    // an EOA with code (e.g. an EIP-7702 delegation designator) takes the strict
    // has-code branch: isValidSignature or nothing — NEVER raw ecrecover. Etch
    // non-1271 runtime code onto Bob's address; his otherwise-valid raw ECDSA
    // signature must now fail (the 1271 call returns no decodable magic value)
    CommitAuth memory auth = _eoaAuth(BOB_PK, lock, _aliceTerms(), _bobTerms());
    vm.etch(BOB, hex'00'); // STOP — returns no data, so 1271 decoding fails

    _expectCommitAliceSideRevert(CHARLIE, auth, '');
  }

  function test_commitAuth_delegatedEoa_selfAuthStillWorks() public {
    // self-auth is checked BEFORE code inspection, so a delegated EOA acting as
    // its own sender is unaffected by its code
    vm.etch(BOB, hex'00');
    _commitAliceSideAs(BOB, _selfAuth(BOB));
    _assertLockState(lock, LockState.Free);
  }

  // ============ ERC-7913 keyed route ============

  function test_commitAuth_keyed_revertsWhen_verifierUntrusted() public {
    bytes memory signer = abi.encodePacked(address(verifierB), bytes('alice-key'));
    _expectCommitAliceSideRevert(
      ALICE, CommitAuth({signer: signer, signature: ''}), abi.encodePacked(IOmnibus.UntrustedVerifier.selector)
    );
  }

  function test_commitAuth_keyed_acceptAll_succeeds() public {
    verifierA.setMode(VerifierMock.Mode.AcceptAll);
    _commitAliceSideAs(ALICE, _keyedAuth(aliceSigner));
    _assertLockState(lock, LockState.Free);
  }

  function test_commitAuth_keyed_acceptMatching_succeedsOnExactInputs() public {
    // digest exactness: prime the mock from the RAW MIRROR (spec re-derivation);
    // the commit only passes if the enforced digest equals the mirror
    verifierA.setMode(VerifierMock.Mode.AcceptMatching);
    bytes32 mirror = _mirrorCommitDigest(lock, _aliceTerms(), _bobTerms(), aliceSigner);
    assertEq(mirror, _aliceDigestFor(aliceSigner), 'mirror must equal the commitDigest view');
    verifierA.prime(bytes('alice-key'), mirror, bytes('envelope'));

    _commitAliceSideAs(ALICE, CommitAuth({signer: aliceSigner, signature: bytes('envelope')}));
    _assertLockState(lock, LockState.Free);
  }

  function test_commitAuth_keyed_acceptMatching_revertsOnUnprimedInputs() public {
    verifierA.setMode(VerifierMock.Mode.AcceptMatching);
    verifierA.prime(bytes('alice-key'), keccak256('some other digest'), bytes('envelope'));

    _expectCommitAliceSideRevert(
      ALICE,
      CommitAuth({signer: aliceSigner, signature: bytes('envelope')}),
      abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commitAuth_keyed_rejectAll_reverts() public {
    verifierA.setMode(VerifierMock.Mode.RejectAll);
    _expectCommitAliceSideRevert(
      ALICE, _keyedAuth(aliceSigner), abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commitAuth_keyed_revertAll_bubbles() public {
    verifierA.setMode(VerifierMock.Mode.RevertAll);
    _expectCommitAliceSideRevert(
      ALICE, _keyedAuth(aliceSigner), abi.encodeWithSignature('Error(string)', 'VerifierMock: revert mode')
    );
  }

  function test_commitAuth_keyed_wrongMagic_reverts() public {
    verifierA.setMode(VerifierMock.Mode.WrongMagic);
    _expectCommitAliceSideRevert(
      ALICE, _keyedAuth(aliceSigner), abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  // ============ Digest exactness: tampered-context perturbations (EOA route) ============

  function _commitPerturbedWith(CommitAuth memory auth, bytes32 _lock, Terms memory party, Terms memory cp) internal {
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.InvalidCommitSignature.selector);
    vm.prank(CHARLIE);
    omnibus.commit{value: _totalNativeForCommit(party)}(_lock, party, cp, auth);
  }

  function test_commitAuth_digest_revertsWhen_lockPerturbed() public {
    CommitAuth memory auth = _eoaAuth(BOB_PK, lock, _aliceTerms(), _bobTerms());
    bytes32 otherLock = omnibus.exposed_generateLock(keccak256('other-secret'));
    _commitPerturbedWith(auth, otherLock, _aliceTerms(), _bobTerms());
  }

  function test_commitAuth_digest_revertsWhen_partyTermsPerturbed() public {
    CommitAuth memory auth = _eoaAuth(BOB_PK, lock, _aliceTerms(), _bobTerms());
    Terms memory perturbed = _aliceTermsOn(block.chainid, _makeNativeAssets(DEFAULT_AMOUNT + 1));
    _commitPerturbedWith(auth, lock, perturbed, _bobTerms());
  }

  function test_commitAuth_digest_revertsWhen_counterpartyTermsPerturbed() public {
    CommitAuth memory auth = _eoaAuth(BOB_PK, lock, _aliceTerms(), _bobTerms());
    Terms memory perturbed = _bobTermsOn(block.chainid, _makeERC20Assets(DEFAULT_AMOUNT + 1));
    _commitPerturbedWith(auth, lock, _aliceTerms(), perturbed);
  }

  function test_commitAuth_digest_revertsWhen_signerHashPerturbed() public {
    // signature valid for BOB's key but the declared blob is swapped to another
    // identity: signerHash binding must reject the transplant
    bytes32 digest = _aliceDigestFor(bobSigner);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOB_PK, digest);
    bytes memory swappedSigner = abi.encodePacked(vm.addr(uint256(keccak256('not-bob'))));

    _expectCommitAliceSideRevert(
      CHARLIE,
      CommitAuth({signer: swappedSigner, signature: abi.encodePacked(r, s, v)}),
      abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commitAuth_digest_revertsWhen_chainIdPerturbed() public {
    // a signature produced for THIS chain's digest must not validate on another
    // chain (block.chainid is a digest ingredient). Terms must move with the
    // chain (enforceChainId), so rebuild them on the new id — the signature was
    // never given a chance to cover chain-999 context
    CommitAuth memory auth = _eoaAuth(BOB_PK, lock, _aliceTerms(), _bobTerms());

    uint256 newChainId = 999;
    vm.chainId(newChainId);
    Terms memory aliceOn999 = _aliceTermsOn(newChainId, _makeNativeAssets(DEFAULT_AMOUNT));
    Terms memory bobOn999 = _bobTermsOn(newChainId, _makeERC20Assets(DEFAULT_AMOUNT));

    _commitPerturbedWith(auth, lock, aliceOn999, bobOn999);
  }

  // ============ Soft-guard semantics (a decision, not an accident) ============

  function test_commitAuth_softGuard_thirdPartyPostsOtherSideWithOwnIdentityAndFunds() public {
    // Alice posts her side (keyed). A THIRD PARTY (Charlie) then posts BOB's side
    // with his OWN identity and OWN funds: the contract never enforces WHICH
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
    omnibus.commit{value: 0}(lock, bob, alice, _selfAuth(CHARLIE));
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
    omnibus.commit{value: required}(lock, alice, bob, _keyedAuth(aliceSigner));

    _assertLockState(lock, LockState.Free);
    assertEq(relayer.balance, 0); // relayer paid everything
    assertEq(omnibus.accruedFees(), fee);
  }
}
