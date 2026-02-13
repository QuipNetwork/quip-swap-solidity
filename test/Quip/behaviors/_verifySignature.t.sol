// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {QuipTest} from '../Quip.t.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title Quip _verifySignature Tests
/// @dev Tests for Quip._verifySignature
contract Quip__verifySignature is QuipTest {
  bytes32 public testTermsDigest;
  WOTSPlus.WinternitzElements internal storedValidSignature;

  function setUp() public override {
    super.setUp();
    // set pqOwner and termsDigest on harness for testing
    quipHarness.setPqOwner(defaultPqOwner);
    testTermsDigest = keccak256('test_terms_digest');
    quipHarness.setTermsDigest(testTermsDigest);
    // create valid signature for the termsDigest
    storedValidSignature = _signMessage(defaultPrivateKey, testTermsDigest);
  }

  // ============ Success Cases ============

  function test_exposed_verifySignature_succeedsWithValidSignature() public view {
    quipHarness.exposed_verifySignature(storedValidSignature);
  }

  // ============ Revert Cases ============

  function test_exposed_verifySignature_revertsWhen_signatureInvalid() public {
    // create signature for wrong message
    bytes32 wrongDigest = keccak256('wrong_digest');
    WOTSPlus.WinternitzElements memory wrongSignature = _signMessage(defaultPrivateKey, wrongDigest);

    vm.expectRevert(IQuip.InvalidSignature.selector);
    quipHarness.exposed_verifySignature(wrongSignature);
  }

  function test_exposed_verifySignature_revertsWhen_signedWithWrongKey() public {
    // generate different key pair
    (, bytes32 otherPrivateKey) = _uniqueKeyPair(999);
    // sign with correct digest but wrong key
    WOTSPlus.WinternitzElements memory wrongKeySignature = _signMessage(otherPrivateKey, testTermsDigest);

    // signature is for correct message but wrong key
    vm.expectRevert(IQuip.InvalidSignature.selector);
    quipHarness.exposed_verifySignature(wrongKeySignature);
  }

  // ============ Fuzz Tests ============

  function testFuzz_exposed_verifySignature_revertsWithWrongDigest(bytes32 wrongDigest) public {
    vm.assume(wrongDigest != testTermsDigest);
    WOTSPlus.WinternitzElements memory wrongSignature = _signMessage(defaultPrivateKey, wrongDigest);

    vm.expectRevert(IQuip.InvalidSignature.selector);
    quipHarness.exposed_verifySignature(wrongSignature);
  }

  function testFuzz_exposed_verifySignature_succeedsWithMatchingSignature(bytes32 seed) public {
    // generate unique key pair and digest
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _generateKeyPair(seed);
    bytes32 digest = keccak256(abi.encodePacked('digest', seed));

    // set up harness with new values
    quipHarness.setPqOwner(pqOwner);
    quipHarness.setTermsDigest(digest);

    // create matching signature
    WOTSPlus.WinternitzElements memory signature = _signMessage(privateKey, digest);

    quipHarness.exposed_verifySignature(signature);
  }
}
