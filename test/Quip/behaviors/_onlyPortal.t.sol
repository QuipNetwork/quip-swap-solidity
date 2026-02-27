// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Quip} from '../../../src/Quip.sol';
import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {QuipTest} from '../Quip.t.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title Malicious Initializer that tries to initialize quips by pretending to be the portal
/// @dev Deployed via LibClone to have portal address in correct bytecode position (same as Quip)
contract MaliciousInitializer {
  /// @notice Returns the portal address from bytecode (same implementation as Quip.PORTAL_FROM_BYTECODE)
  /// @dev Uses LibClone.argsOnClone to read immutable args from the same bytecode position
  function PORTAL_FROM_BYTECODE() public view returns (address) {
    return abi.decode(LibClone.argsOnClone(address(this), 0, 32), (address));
  }

  /// @notice Attempts to call initializeCoupled on a quip
  function attackInitializeCoupled(
    address quip,
    WOTSPlus.WinternitzAddress calldata pqOwner,
    bytes32 termsDigest
  ) external {
    Quip(payable(quip)).initializeCoupled(pqOwner, termsDigest);
  }

  /// @notice Attempts to call initializeUncoupled on a quip
  function attackInitializeUncoupled(
    address quip,
    WOTSPlus.WinternitzAddress calldata pqOwner,
    bytes32 termsDigest
  ) external {
    Quip(payable(quip)).initializeUncoupled(pqOwner, termsDigest);
  }
}

/// @title Quip _onlyPortal Tests
/// @dev Tests for Quip._onlyPortal modifier
///      Note: Testing _onlyPortal requires a properly deployed clone since PORTAL_FROM_BYTECODE()
///      reads the portal address from the clone's bytecode. We test via initializeCoupled which
///      uses the onlyPortal modifier.
contract Quip__onlyPortal is QuipTest {
  // ============ Happy Paths ============

  function test_exposed_onlyPortal_succeedsWhen_calledByPortal() public view {
    // The onlyPortal modifier succeeds when called by the portal during initialization
    // This is implicitly tested by deployedQuip being successfully initialized
    // We can verify by checking the quip is properly set up
    assertEq(deployedQuip.PORTAL_FROM_BYTECODE(), address(portal));
    assertEq(deployedQuip.pqOwnerHash(), defaultPqOwnerHash);
  }

  // ============ Reversions ============

  function test_exposed_onlyPortal_revertsWhen_calledByNonPortal() public {
    // Calling a function protected by onlyPortal from a non-portal address reverts
    WOTSPlus.WinternitzAddress memory fakePqOwner =
      WOTSPlus.WinternitzAddress({publicSeed: bytes32(uint256(1)), publicKeyHash: bytes32(uint256(2))});

    vm.expectRevert(IQuip.CallerNotPortal.selector);
    deployedQuip.initializeCoupled(fakePqOwner, bytes32(uint256(3)));
  }

  function testFuzz_exposed_onlyPortal_revertsWhen_calledByRandomAddress(address caller) public {
    vm.assume(caller != address(portal));
    vm.assume(caller != address(0));

    WOTSPlus.WinternitzAddress memory fakePqOwner =
      WOTSPlus.WinternitzAddress({publicSeed: bytes32(uint256(1)), publicKeyHash: bytes32(uint256(2))});

    vm.prank(caller);
    vm.expectRevert(IQuip.CallerNotPortal.selector);
    deployedQuip.initializeCoupled(fakePqOwner, bytes32(uint256(3)));
  }

  // ============ Attacks ============

  function test_onlyPortal_initializeCoupled_revertsWhen_calledByMaliciousInitializer() public {
    // Deploy MaliciousInitializer and clone it with portal address in bytecode
    MaliciousInitializer maliciousImpl = new MaliciousInitializer();
    address maliciousClone = LibClone.clone(address(maliciousImpl), abi.encode(address(portal)));
    MaliciousInitializer maliciousInitializer = MaliciousInitializer(maliciousClone);

    // Deploy a fresh quip clone (uninitialized) with portal address in bytecode
    Quip quipImpl = new Quip();
    address uninitializedQuip = LibClone.clone(address(quipImpl), abi.encode(address(portal)));

    // Verify BOTH the quip and malicious initializer read the same portal from bytecode
    assertEq(Quip(payable(uninitializedQuip)).PORTAL_FROM_BYTECODE(), address(portal));
    assertEq(maliciousInitializer.PORTAL_FROM_BYTECODE(), address(portal));
    // This proves the attacker has the portal address in the correct bytecode position

    // Verify quip is uninitialized (termsDigest is zero)
    assertEq(Quip(payable(uninitializedQuip)).termsDigest(), bytes32(0));

    // Malicious initializer tries to initialize the quip
    WOTSPlus.WinternitzAddress memory fakePqOwner =
      WOTSPlus.WinternitzAddress({publicSeed: keccak256('fake_seed'), publicKeyHash: keccak256('fake_pubkey')});
    bytes32 fakeTermsDigest = keccak256('fake_terms');

    // Attack fails because quip checks msg.sender == PORTAL_FROM_BYTECODE()
    // The malicious initializer is NOT the portal, even though it knows the portal address
    vm.expectRevert(IQuip.CallerNotPortal.selector);
    maliciousInitializer.attackInitializeCoupled(uninitializedQuip, fakePqOwner, fakeTermsDigest);

    // Verify quip was NOT initialized (termsDigest should still be zero)
    assertEq(Quip(payable(uninitializedQuip)).termsDigest(), bytes32(0));
  }

  function test_onlyPortal_initializeUncoupled_revertsWhen_calledByMaliciousInitializer() public {
    // Deploy MaliciousInitializer and clone it with portal address in bytecode
    MaliciousInitializer maliciousImpl = new MaliciousInitializer();
    address maliciousClone = LibClone.clone(address(maliciousImpl), abi.encode(address(portal)));
    MaliciousInitializer maliciousInitializer = MaliciousInitializer(maliciousClone);

    // Deploy a fresh quip clone (uninitialized) with portal address in bytecode
    Quip quipImpl = new Quip();
    address uninitializedQuip = LibClone.clone(address(quipImpl), abi.encode(address(portal)));

    // Verify BOTH the quip and malicious initializer read the same portal from bytecode
    assertEq(Quip(payable(uninitializedQuip)).PORTAL_FROM_BYTECODE(), address(portal));
    assertEq(maliciousInitializer.PORTAL_FROM_BYTECODE(), address(portal));
    // This proves the attacker has the portal address in the correct bytecode position

    // Verify quip is uninitialized (termsDigest is zero)
    assertEq(Quip(payable(uninitializedQuip)).termsDigest(), bytes32(0));

    // Malicious initializer tries to initialize the quip
    WOTSPlus.WinternitzAddress memory fakePqOwner =
      WOTSPlus.WinternitzAddress({publicSeed: keccak256('fake_seed'), publicKeyHash: keccak256('fake_pubkey')});
    bytes32 fakeTermsDigest = keccak256('fake_terms');

    // Attack fails because quip checks msg.sender == PORTAL_FROM_BYTECODE()
    // The malicious initializer is NOT the portal, even though it knows the portal address
    vm.expectRevert(IQuip.CallerNotPortal.selector);
    maliciousInitializer.attackInitializeUncoupled(uninitializedQuip, fakePqOwner, fakeTermsDigest);

    // Verify quip was NOT initialized (termsDigest should still be zero)
    assertEq(Quip(payable(uninitializedQuip)).termsDigest(), bytes32(0));
  }
}
