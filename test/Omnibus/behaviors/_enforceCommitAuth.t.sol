// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {AuthHelper} from '../../utils/AuthHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus _enforceCommitAuth Tests
/// @dev direct unit tests of the commit-auth guard via the harness — no commit
/// ceremony. At this level the digest is an opaque input (whether it is the
/// RIGHT digest for a swap is commit's job — see the digest-binding tests in
/// commit.t.sol, which also proves the wiring: commit CALLS this guard).
/// Route discrimination: an empty auth.signature selects the WALLET route
/// (msg.sender must be registered in the wallet factory), any other signature
/// the KEYED route (verify over the digest)
contract Omnibus__enforceCommitAuth is OmnibusTest {
  bytes32 internal constant DIGEST = keccak256('some digest');

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

  function test_enforceCommitAuth_wallet_revertsWhen_signerIsBareAddress() public {
    // the malformed-blob gate is SHARED: a registered wallet with a bare-address
    // blob still fails the shape check — the factory is never even consulted
    // (a reverting factory proves it)
    _registerWallet(address(this));
    _mockFactoryReverts('factory must not be called');
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.walletAuth(abi.encodePacked(ALICE)), DIGEST);
  }

  // ============ Activity gate (keyed route only) ============

  function test_enforceCommitAuth_revertsWhen_verifierNotActive() public {
    vm.expectRevert(IOmnibus.VerifierNotActive.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(abi.encodePacked(address(verifierB), bytes('key'))), DIGEST);
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
    _mockVerifierReverts('verifier reverted');
    vm.expectRevert(abi.encodeWithSignature('Error(string)', 'verifier reverted'));
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(aliceSigner), DIGEST);
  }

  function test_enforceCommitAuth_revertsWhen_wrongMagicReturned() public {
    // a plausible-but-wrong selector must NOT be treated as valid
    _mockVerifierReturns(bytes4(0x12345678));
    vm.expectRevert(IOmnibus.InvalidCommitSignature.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(aliceSigner), DIGEST);
  }

  // ============ Wallet route: factory membership ============

  function test_enforceCommitAuth_wallet_succeeds_whenSenderRegistered() public {
    _registerWallet(address(this));
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.walletAuth(aliceSigner), DIGEST);
  }

  function test_enforceCommitAuth_wallet_revertsWhen_senderNotRegistered() public {
    vm.expectRevert(IOmnibus.NotQuipWallet.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.walletAuth(aliceSigner), DIGEST);
  }

  function test_enforceCommitAuth_wallet_revertsWhen_onlyOtherAccountRegistered() public {
    // membership is checked against msg.sender: ALICE being a wallet does not
    // let anyone else borrow the route
    _registerWallet(ALICE);
    vm.expectRevert(IOmnibus.NotQuipWallet.selector);
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.walletAuth(aliceSigner), DIGEST);
  }

  function test_enforceCommitAuth_wallet_skipsVerifierActivity_inactiveVerifier() public {
    // the signer blob is attribution only: a blob declaring the INACTIVE
    // verifierB passes for a registered wallet (no activity check, no call)
    _registerWallet(address(this));
    omnibus.exposed_enforceCommitAuthorized(
      AuthHelper.walletAuth(abi.encodePacked(address(verifierB), bytes('key'))), DIGEST
    );
  }

  function test_enforceCommitAuth_wallet_skipsVerifierActivity_codelessPrefix() public {
    // even a codeless (EOA) verifier prefix passes: the prefix is never
    // resolved to a contract on this route
    _registerWallet(address(this));
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.walletAuth(abi.encodePacked(ALICE, bytes('key'))), DIGEST);
  }

  function test_enforceCommitAuth_wallet_revertsWhen_factoryReverts_bubbles() public {
    _mockFactoryReverts('factory reverted');
    vm.expectRevert(abi.encodeWithSignature('Error(string)', 'factory reverted'));
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.walletAuth(aliceSigner), DIGEST);
  }

  // ============ Route exclusivity ============

  function test_enforceCommitAuth_wallet_neverCallsVerify() public {
    // route exclusivity: an empty signature must NEVER reach verify (a
    // reverting verify proves it was not consulted)
    _mockVerifierReverts('verify must not be called');
    _registerWallet(address(this));
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.walletAuth(aliceSigner), DIGEST);
  }

  function test_enforceCommitAuth_keyed_neverCallsFactory() public {
    // route exclusivity the other way: a non-empty signature must NEVER
    // consult the factory registry
    _mockFactoryReverts('vaultIdOf must not be called');
    omnibus.exposed_enforceCommitAuthorized(AuthHelper.auth(aliceSigner), DIGEST);
  }
}
