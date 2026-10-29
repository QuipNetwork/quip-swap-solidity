// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CommitAuth, IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {AuthHelper} from '../../utils/AuthHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';
import {
  IERC7913TransientAttestation
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913TransientAttestation.sol';

/// @title Omnibus _enforceCommitAuth Tests
/// @dev direct unit tests of the commit-auth guard via the harness — no commit
/// ceremony. At this level the digest is an opaque input (whether it is the
/// RIGHT digest for a swap is commit's job — see the digest-binding tests in
/// commit.t.sol, which also proves the wiring: commit CALLS this guard).
/// Route discrimination: an empty auth.signature selects the ATTESTED route
/// (wasVerified over the reconstructed envelope), any other signature the
/// KEYED route (verify over the digest)
contract Omnibus__enforceCommitAuth is OmnibusTest {
  bytes32 internal constant DIGEST = keccak256('some digest');
  bytes32 internal constant WALLET_BINDING = keccak256('some wallet binding');

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

  /// @dev baseline: verifierA denies every wasVerified query
  function _mockAttestationDeniesAll() internal {
    vm.mockCall(
      address(verifierA), abi.encodeWithSelector(IERC7913TransientAttestation.wasVerified.selector), abi.encode(false)
    );
  }

  /// @dev verifierA attests EXACTLY (account, keyHash, hash) and denies all
  /// else — the mock mirror of one prior successful verifyAndAttest
  function _mockAttestedOnly(address account, bytes32 keyHash, bytes32 hash) internal {
    _mockAttestationDeniesAll();
    vm.mockCall(
      address(verifierA),
      abi.encodeCall(IERC7913TransientAttestation.wasVerified, (account, keyHash, hash)),
      abi.encode(true)
    );
  }

  /// @dev the attested route's composite envelope hash — spec re-derivation
  function _envelopeHash(bytes32 walletBinding, bytes32 digest) internal view returns (bytes32) {
    return keccak256(abi.encode(omnibus.ENVELOPE_TYPEHASH(), walletBinding, digest));
  }

  /// @dev keyHash over the raw key bytes of a signer blob (spec: keccak256 of
  /// the key PORTION, not the whole blob)
  function _keyHash(bytes memory signer) internal pure returns (bytes32) {
    bytes memory key = new bytes(signer.length - 20);
    for (uint256 i = 0; i < key.length; i++) {
      key[i] = signer[20 + i];
    }
    return keccak256(key);
  }

  // ============ Malformed blobs (<= 20 bytes; both routes) ============

  function test_enforceCommitAuth_revertsWhen_signerEmpty() public {
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(''), DIGEST);
  }

  function test_enforceCommitAuth_revertsWhen_signerOneByte() public {
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(hex'01'), DIGEST);
  }

  function test_enforceCommitAuth_revertsWhen_signerNineteenBytes() public {
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(new bytes(19)), DIGEST);
  }

  function test_enforceCommitAuth_revertsWhen_signerIsBareAddress() public {
    // exactly 20 bytes is a bare address: keyed identities only
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(abi.encodePacked(ALICE)), DIGEST);
  }

  function test_enforceCommitAuth_revertsWhen_signerIsBareContractAddress() public {
    // has-code changes nothing (ERC-1271 removed): still malformed at 20 bytes
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(abi.encodePacked(address(verifierA))), DIGEST);
  }

  function test_enforceCommitAuth_attested_revertsWhen_signerIsBareAddress() public {
    // the malformed-blob gate is SHARED: the attested route never reaches the
    // verifier for a bare address either
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.attestedAuth(abi.encodePacked(ALICE), WALLET_BINDING), DIGEST);
  }

  // ============ Activity gate (both routes) ============

  function test_enforceCommitAuth_revertsWhen_verifierNotActive() public {
    vm.expectRevert(IOmnibus.VerifierNotActive.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(abi.encodePacked(address(verifierB), bytes('key'))), DIGEST);
  }

  function test_enforceCommitAuth_attested_revertsWhen_verifierNotActive() public {
    // activity is checked BEFORE the attestation lookup: an inactive verifier
    // is never consulted, so its attestations (real or hostile) are worthless
    vm.expectRevert(IOmnibus.VerifierNotActive.selector);
    omnibus.exposed_enforceCommitAuthorized(
      AuthHelper.attestedAuth(abi.encodePacked(address(verifierB), bytes('key')), WALLET_BINDING), DIGEST
    );
  }

  // ============ Keyed route: verifier result handling ============

  function test_enforceCommitAuth_succeeds_whenVerifierAccepts() public view {
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(aliceSigner), DIGEST);
  }

  function test_enforceCommitAuth_succeedsOnExactInputs() public {
    _mockVerifierAcceptsOnly(bytes('alice-key'), DIGEST, bytes('envelope'));
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(aliceSigner), DIGEST);
  }

  function test_enforceCommitAuth_revertsWhen_inputsNotAccepted() public {
    _mockVerifierAcceptsOnly(bytes('alice-key'), keccak256('a DIFFERENT digest'), bytes('envelope'));
    vm.expectRevert(IOmnibus.InvalidCommitSignature.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(aliceSigner), DIGEST);
  }

  function test_enforceCommitAuth_revertsWhen_verifierRejects() public {
    _mockVerifierRejectsAll();
    vm.expectRevert(IOmnibus.InvalidCommitSignature.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(aliceSigner), DIGEST);
  }

  function test_enforceCommitAuth_revertsWhen_verifierReverts_bubbles() public {
    vm.mockCallRevert(
      address(verifierA),
      abi.encodeWithSelector(IERC7913SignatureVerifier.verify.selector),
      abi.encodeWithSignature('Error(string)', 'verifier reverted')
    );
    vm.expectRevert(abi.encodeWithSignature('Error(string)', 'verifier reverted'));
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(aliceSigner), DIGEST);
  }

  function test_enforceCommitAuth_revertsWhen_wrongMagicReturned() public {
    // a plausible-but-wrong selector must NOT be treated as valid
    vm.mockCall(
      address(verifierA),
      abi.encodeWithSelector(IERC7913SignatureVerifier.verify.selector),
      abi.encode(bytes4(0x12345678))
    );
    vm.expectRevert(IOmnibus.InvalidCommitSignature.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(aliceSigner), DIGEST);
  }

  // ============ Attested route: envelope reconstruction + lookup ============

  function test_enforceCommitAuth_attested_succeeds_whenTripleAttested() public {
    // the guard must query EXACTLY (msg.sender, keyHash(key portion),
    // envelopeHash(binding, digest)) — the mock attests only that triple
    _mockAttestedOnly(address(this), _keyHash(aliceSigner), _envelopeHash(WALLET_BINDING, DIGEST));
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.attestedAuth(aliceSigner, WALLET_BINDING), DIGEST);
  }

  function test_enforceCommitAuth_attested_revertsWhen_nothingAttested() public {
    _mockAttestationDeniesAll();
    vm.expectRevert(IOmnibus.AttestationNotFound.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.attestedAuth(aliceSigner, WALLET_BINDING), DIGEST);
  }

  function test_enforceCommitAuth_attested_revertsWhen_walletBindingWrong() public {
    // attested for one binding, presented with another: reconstructed envelope
    // differs, lookup misses
    _mockAttestedOnly(address(this), _keyHash(aliceSigner), _envelopeHash(WALLET_BINDING, DIGEST));
    vm.expectRevert(IOmnibus.AttestationNotFound.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.attestedAuth(aliceSigner, keccak256('other binding')), DIGEST);
  }

  function test_enforceCommitAuth_attested_revertsWhen_digestDiffers() public {
    // attestation covers the envelope over DIGEST; a different digest half
    // reconstructs a different envelope
    _mockAttestedOnly(address(this), _keyHash(aliceSigner), _envelopeHash(WALLET_BINDING, DIGEST));
    vm.expectRevert(IOmnibus.AttestationNotFound.selector);
    omnibus.exposed_enforceCommitAuthorized(
      AuthHelper.attestedAuth(aliceSigner, WALLET_BINDING), keccak256('a DIFFERENT digest')
    );
  }

  function test_enforceCommitAuth_attested_revertsWhen_accountIsNotSender() public {
    // attestation exists for ALICE as account, but the caller here is the test
    // contract: account binding must reject the borrow
    _mockAttestedOnly(ALICE, _keyHash(aliceSigner), _envelopeHash(WALLET_BINDING, DIGEST));
    vm.expectRevert(IOmnibus.AttestationNotFound.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.attestedAuth(aliceSigner, WALLET_BINDING), DIGEST);
  }

  function test_enforceCommitAuth_attested_revertsWhen_keyDiffers() public {
    // attested under alice's key; declared blob carries another key — keyHash
    // dimension must miss
    _mockAttestedOnly(address(this), _keyHash(aliceSigner), _envelopeHash(WALLET_BINDING, DIGEST));
    bytes memory otherSigner = abi.encodePacked(address(verifierA), bytes('other-key'));
    vm.expectRevert(IOmnibus.AttestationNotFound.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.attestedAuth(otherSigner, WALLET_BINDING), DIGEST);
  }

  function test_enforceCommitAuth_attested_revertsWhen_verifierLacksAttestationSurface_bubbles() public {
    // an active verifier WITHOUT wasVerified (pre-attestation deploy) reverts on
    // the missing selector — a rejection, never a silent accept or a fallback
    vm.mockCallRevert(address(verifierA), abi.encodeWithSelector(IERC7913TransientAttestation.wasVerified.selector), '');
    vm.expectRevert();
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.attestedAuth(aliceSigner, WALLET_BINDING), DIGEST);
  }

  function test_enforceCommitAuth_attested_neverCallsVerify() public {
    // route exclusivity: an empty signature must NEVER reach verify (a
    // reverting verify proves it was not consulted)
    vm.mockCallRevert(
      address(verifierA),
      abi.encodeWithSelector(IERC7913SignatureVerifier.verify.selector),
      abi.encodeWithSignature('Error(string)', 'verify must not be called')
    );
    _mockAttestedOnly(address(this), _keyHash(aliceSigner), _envelopeHash(WALLET_BINDING, DIGEST));
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.attestedAuth(aliceSigner, WALLET_BINDING), DIGEST);
  }

  function test_enforceCommitAuth_keyed_neverCallsWasVerified() public {
    // route exclusivity the other way: a non-empty signature must NEVER
    // consult the attestation registry
    vm.mockCallRevert(
      address(verifierA),
      abi.encodeWithSelector(IERC7913TransientAttestation.wasVerified.selector),
      abi.encodeWithSignature('Error(string)', 'wasVerified must not be called')
    );
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(aliceSigner), DIGEST);
  }
}
