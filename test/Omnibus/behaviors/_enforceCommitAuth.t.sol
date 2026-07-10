// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';

/// @title Omnibus _enforceCommitAuth Tests
/// @dev direct unit tests of the commit-auth guard via the harness — no commit
/// ceremony. At this level the digest is an opaque input (whether it is the
/// RIGHT digest for a swap is commit's job — see the digest-binding tests in
/// commit.t.sol, which also proves the wiring: commit CALLS this guard)
contract Omnibus__enforceCommitAuth is OmnibusTest {
  bytes32 internal constant DIGEST = keccak256('some digest');

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

  // ============ Malformed blobs (<= 20 bytes) ============

  function test_enforceCommitAuth_revertsWhen_signerEmpty() public {
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized('', DIGEST, '');
  }

  function test_enforceCommitAuth_revertsWhen_signerOneByte() public {
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized(hex'01', DIGEST, '');
  }

  function test_enforceCommitAuth_revertsWhen_signerNineteenBytes() public {
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized(new bytes(19), DIGEST, '');
  }

  function test_enforceCommitAuth_revertsWhen_signerIsBareAddress() public {
    // exactly 20 bytes is a bare address: keyed identities only
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized(abi.encodePacked(ALICE), DIGEST, '');
  }

  function test_enforceCommitAuth_revertsWhen_signerIsBareContractAddress() public {
    // has-code changes nothing (ERC-1271 removed): still malformed at 20 bytes
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized(abi.encodePacked(address(verifierA)), DIGEST, 'sig');
  }

  // ============ Activity gate ============

  function test_enforceCommitAuth_revertsWhen_verifierNotActive() public {
    vm.expectRevert(IOmnibus.VerifierNotActive.selector);
    omnibus.exposed_enforceCommitAuthorized(abi.encodePacked(address(verifierB), bytes('key')), DIGEST, '');
  }

  // ============ Verifier result handling ============

  function test_enforceCommitAuth_succeeds_whenVerifierAccepts() public view {
    omnibus.exposed_enforceCommitAuthorized(aliceSigner, DIGEST, '');
  }

  function test_enforceCommitAuth_succeedsOnExactInputs() public {
    _mockVerifierAcceptsOnly(bytes('alice-key'), DIGEST, bytes('envelope'));
    omnibus.exposed_enforceCommitAuthorized(aliceSigner, DIGEST, bytes('envelope'));
  }

  function test_enforceCommitAuth_revertsWhen_inputsNotAccepted() public {
    _mockVerifierAcceptsOnly(bytes('alice-key'), keccak256('a DIFFERENT digest'), bytes('envelope'));
    vm.expectRevert(IOmnibus.InvalidCommitSignature.selector);
    omnibus.exposed_enforceCommitAuthorized(aliceSigner, DIGEST, bytes('envelope'));
  }

  function test_enforceCommitAuth_revertsWhen_verifierRejects() public {
    _mockVerifierRejectsAll();
    vm.expectRevert(IOmnibus.InvalidCommitSignature.selector);
    omnibus.exposed_enforceCommitAuthorized(aliceSigner, DIGEST, '');
  }

  function test_enforceCommitAuth_revertsWhen_verifierReverts_bubbles() public {
    vm.mockCallRevert(
      address(verifierA),
      abi.encodeWithSelector(IERC7913SignatureVerifier.verify.selector),
      abi.encodeWithSignature('Error(string)', 'verifier reverted')
    );
    vm.expectRevert(abi.encodeWithSignature('Error(string)', 'verifier reverted'));
    omnibus.exposed_enforceCommitAuthorized(aliceSigner, DIGEST, '');
  }

  function test_enforceCommitAuth_revertsWhen_wrongMagicReturned() public {
    // a plausible-but-wrong selector must NOT be treated as valid
    vm.mockCall(
      address(verifierA),
      abi.encodeWithSelector(IERC7913SignatureVerifier.verify.selector),
      abi.encode(bytes4(0x12345678))
    );
    vm.expectRevert(IOmnibus.InvalidCommitSignature.selector);
    omnibus.exposed_enforceCommitAuthorized(aliceSigner, DIGEST, '');
  }
}
