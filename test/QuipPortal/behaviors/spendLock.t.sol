// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../../src/Quip.sol';
import {QuipPortal} from '../../../src/QuipPortal.sol';
import {QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {IQuipPortal, LockState} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';

/// @title Malicious Quip that inherits from Quip but adds a direct spendLock call
/// @dev Deployed via LibClone to have portal address in correct bytecode position
contract MaliciousQuip is Quip {
  /// @notice Directly calls spendLock on the portal (bypassing claim/reclaim)
  function callSpendLock(bytes32 _lock) external {
    IQuipPortal(PORTAL_FROM_BYTECODE()).spendLock(_lock);
  }
}

/// @title QuipPortal spendLock Tests
/// @dev Tests for QuipPortal.spendLock
contract QuipPortal_spendLock is QuipPortalTest {
  Quip public spendLockQuip;
  bytes32 public testLock;
  bytes public testKey;

  // ============ setUp ============

  function setUp() public override {
    super.setUp();

    // Deploy a quip to set QUIP_CODEHASH and have a valid lock
    testKey = abi.encodePacked('spendlock_test_key');
    testLock = keccak256(testKey);
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(testLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    spendLockQuip = Quip(payable(quipAddr));
  }

  // ============ test_setUp ============

  /// @dev Override test_setUp because this test deploys a quip in setUp, so accumulatedFees != 0
  function test_setUp() public view override {
    assertEq(portal.VERSION(), 1);
    assertEq(portal.MAX_FEE(), MAX_FEE);
    assertEq(portal.creationFee(), CREATION_FEE);
    // accumulatedFees is CREATION_FEE because we deployed a quip in setUp
    assertEq(portal.accumulatedFees(), CREATION_FEE);
    assertEq(portal.admin(), ADMIN);
    // Lock should be Free after single deployment
    assertEq(uint256(portal.lockState(testLock)), uint256(LockState.Free));
  }

  // ============ Happy Paths ============

  function test_spendLock_transitionsFromFreeToSpent() public {
    // Verify initial state
    assertEq(uint256(portal.lockState(testLock)), uint256(LockState.Free));

    // Trigger spendLock via claim (which calls spendLock internally)
    QuipTerms memory terms = _makeDefaultQuipTerms();
    spendLockQuip.claim(testKey, terms);

    // Verify final state
    assertEq(uint256(portal.lockState(testLock)), uint256(LockState.Spent));
  }

  function test_spendLock_isIdempotentWhenAlreadySpent() public {
    // Setup: deploy two quips with the same lock (same-chain swap scenario)
    bytes memory anotherKey = abi.encodePacked('another_key');
    bytes32 newLock = keccak256(anotherKey);
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // Verify initial state
    assertEq(uint256(portal.lockState(newLock)), uint256(LockState.Unused));

    // Alice deploys first quip (Unused -> Free)
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(newLock, terms);
    Vm.Log[] memory logs = vm.getRecordedLogs();
    address aliceQuipAddr = _findQuipCreatedAddress(logs);
    Quip aliceQuip = Quip(payable(aliceQuipAddr));

    // Verify state after first deployment
    assertEq(uint256(portal.lockState(newLock)), uint256(LockState.Free));

    // Bob deploys second quip with same lock (Free -> Spent)
    vm.prank(BOB);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(newLock, terms);
    Vm.Log[] memory logs2 = vm.getRecordedLogs();
    address bobQuipAddr = _findQuipCreatedAddress(logs2);
    Quip bobQuip = Quip(payable(bobQuipAddr));

    // Verify state after second deployment
    assertEq(uint256(portal.lockState(newLock)), uint256(LockState.Spent));

    // Alice's quip can still claim (spendLock is idempotent when already Spent)
    aliceQuip.claim(anotherKey, terms);

    // Verify state unchanged after first claim
    assertEq(uint256(portal.lockState(newLock)), uint256(LockState.Spent));

    // Bob's quip can also claim (spendLock is idempotent)
    bobQuip.claim(anotherKey, terms);

    // Verify final state
    assertEq(uint256(portal.lockState(newLock)), uint256(LockState.Spent));
  }

  function test_spendLock_emitsSpentLock() public {
    // Verify initial state
    assertEq(uint256(portal.lockState(testLock)), uint256(LockState.Free));

    QuipTerms memory terms = _makeDefaultQuipTerms();

    vm.recordLogs();
    spendLockQuip.claim(testKey, terms);

    // Verify final state
    assertEq(uint256(portal.lockState(testLock)), uint256(LockState.Spent));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool found = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.SpentLock.selector) {
        assertEq(logs[i].topics[1], testLock); // indexed lock
        found = true;
        break;
      }
    }
    assertTrue(found, 'SpentLock not found');
  }

  function test_QUIP_CODEHASH_setOnFirstDeployment() public {
    // Deploy fresh portal
    Quip freshQuipImpl = new Quip();
    QuipPortal freshPortal = new QuipPortal(ADMIN, address(freshQuipImpl), MAX_FEE, CREATION_FEE);

    // Initially zero
    assertEq(freshPortal.QUIP_CODEHASH(), bytes32(0));

    // Deploy first quip
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    bytes32 lock1 = keccak256('first_quip');

    // Verify lock state before
    assertEq(uint256(freshPortal.lockState(lock1)), uint256(LockState.Unused));

    vm.prank(ALICE);
    vm.recordLogs();
    freshPortal.deployCoupledQuip{value: nativeRequired}(lock1, terms);

    // Verify lock state after
    assertEq(uint256(freshPortal.lockState(lock1)), uint256(LockState.Free));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quip1Addr = _findQuipCreatedAddress(logs);

    // QUIP_CODEHASH should now be set
    bytes32 expectedHash = freshPortal.QUIP_CODEHASH();
    assertTrue(expectedHash != bytes32(0));
    assertEq(expectedHash, quip1Addr.codehash);
  }

  function test_QUIP_CODEHASH_sameForAllClones() public {
    // Deploy fresh portal
    Quip freshQuipImpl = new Quip();
    QuipPortal freshPortal = new QuipPortal(ADMIN, address(freshQuipImpl), MAX_FEE, CREATION_FEE);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // Deploy first quip
    bytes32 lock1 = keccak256('quip_one');

    // Verify initial state
    assertEq(uint256(freshPortal.lockState(lock1)), uint256(LockState.Unused));

    vm.prank(ALICE);
    vm.recordLogs();
    freshPortal.deployCoupledQuip{value: nativeRequired}(lock1, terms);
    Vm.Log[] memory logs1 = vm.getRecordedLogs();
    address quip1 = _findQuipCreatedAddress(logs1);

    // Verify state after first deployment
    assertEq(uint256(freshPortal.lockState(lock1)), uint256(LockState.Free));

    // Deploy second quip with different lock
    bytes32 lock2 = keccak256('quip_two');

    // Verify initial state for second lock
    assertEq(uint256(freshPortal.lockState(lock2)), uint256(LockState.Unused));

    vm.prank(BOB);
    vm.recordLogs();
    freshPortal.deployCoupledQuip{value: nativeRequired}(lock2, terms);
    Vm.Log[] memory logs2 = vm.getRecordedLogs();
    address quip2 = _findQuipCreatedAddress(logs2);

    // Verify state after second deployment
    assertEq(uint256(freshPortal.lockState(lock2)), uint256(LockState.Free));

    // Both quips should have the same codehash
    assertEq(quip1.codehash, quip2.codehash);

    // And it should match the stored QUIP_CODEHASH
    assertEq(quip1.codehash, freshPortal.QUIP_CODEHASH());
  }

  // ============ Reversions ============

  function test_spendLock_revertsWhen_calledByEOA() public {
    // Verify initial state
    assertEq(uint256(portal.lockState(testLock)), uint256(LockState.Free));

    // EOA tries to call spendLock directly
    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.CallerNotQuip.selector);
    portal.spendLock(testLock);

    // Verify lock state unchanged
    assertEq(uint256(portal.lockState(testLock)), uint256(LockState.Free));
  }

  function test_spendLock_revertsWhen_calledByArbitraryContract() public {
    // Verify initial state
    assertEq(uint256(portal.lockState(testLock)), uint256(LockState.Free));

    // Any random contract that's not a quip clone
    vm.prank(address(mockERC20));
    vm.expectRevert(IQuipPortal.CallerNotQuip.selector);
    portal.spendLock(testLock);

    // Verify lock state unchanged
    assertEq(uint256(portal.lockState(testLock)), uint256(LockState.Free));
  }

  function test_spendLock_revertsWhen_noQuipsDeployedYet() public {
    // Deploy a fresh portal with no quips deployed
    Quip freshQuipImpl = new Quip();
    QuipPortal freshPortal = new QuipPortal(ADMIN, address(freshQuipImpl), MAX_FEE, CREATION_FEE);

    // QUIP_CODEHASH is bytes32(0) since no quips deployed
    assertEq(freshPortal.QUIP_CODEHASH(), bytes32(0));

    // Any caller will fail because their codehash won't match bytes32(0)
    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.CallerNotQuip.selector);
    freshPortal.spendLock(testLock);
  }

  // ============ Attacks ============

  function test_spendLock_revertsWhen_calledByMaliciousQuip() public {
    // Verify initial state
    assertEq(uint256(portal.lockState(testLock)), uint256(LockState.Free));

    // Deploy MaliciousQuip implementation
    MaliciousQuip maliciousImpl = new MaliciousQuip();

    // Deploy as clone with portal address in bytecode (like real quips)
    address maliciousClone = LibClone.clone(address(maliciousImpl), abi.encode(address(portal)));

    // Verify the malicious clone can read the portal address correctly
    assertEq(MaliciousQuip(payable(maliciousClone)).PORTAL_FROM_BYTECODE(), address(portal));

    // Verify the malicious clone has a DIFFERENT codehash than legitimate quips
    assertTrue(maliciousClone.codehash != portal.QUIP_CODEHASH(), 'Codehash should differ');

    // Attacker tries to spend a lock via malicious quip
    vm.expectRevert(IQuipPortal.CallerNotQuip.selector);
    MaliciousQuip(payable(maliciousClone)).callSpendLock(testLock);

    // Verify lock state unchanged
    assertEq(uint256(portal.lockState(testLock)), uint256(LockState.Free));
  }
}
