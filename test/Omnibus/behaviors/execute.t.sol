// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

/// @title Omnibus execute Tests
/// @dev Tests for Omnibus.execute
contract Omnibus_execute is OmnibusTest {
  using AssetHelper for *;

  // ============ Success Cases ============

  function test_execute_sameChainSwap() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Record balances before
    uint256 bobRecipientNativeBefore = BOB_RECIPIENT.balance;
    uint256 aliceRecipientERC20Before = mockERC20.balanceOf(ALICE_RECIPIENT);

    omnibus.execute(SECRET, alice, bob);

    // Alice's native assets go to Bob's recipient (counterparty.recipient)
    assertEq(BOB_RECIPIENT.balance - bobRecipientNativeBefore, DEFAULT_AMOUNT);
    // Bob's ERC20 assets go to Alice's recipient (party.recipient)
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientERC20Before, DEFAULT_AMOUNT);
  }

  function test_execute_transfersPartyAssetsToCounterpartyRecipient() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;

    omnibus.execute(SECRET, alice, bob);

    // Party (alice) assets go to counterparty (bob) recipient
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, DEFAULT_AMOUNT);
  }

  function test_execute_transfersCounterpartyAssetsToPartyRecipient() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    uint256 aliceRecipientBefore = mockERC20.balanceOf(ALICE_RECIPIENT);

    omnibus.execute(SECRET, alice, bob);

    // Counterparty (bob) assets go to party (alice) recipient
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientBefore, DEFAULT_AMOUNT);
  }

  function test_execute_partyOnChain_counterpartyCrossChain() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobCrossChainTerms();

    // Only alice commits (cross-chain scenario)
    _commitFor(ALICE, lock, alice, bob);

    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;
    uint256 aliceRecipientERC20Before = mockERC20.balanceOf(ALICE_RECIPIENT);

    omnibus.execute(SECRET, alice, bob);

    // Party assets transferred to counterparty recipient
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, DEFAULT_AMOUNT);
    // Counterparty is cross-chain, so no transfer for counterparty assets
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT), aliceRecipientERC20Before);
  }

  function test_execute_emitsClaimEvent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    vm.recordLogs();
    omnibus.execute(SECRET, alice, bob);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool foundEvent = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IOmnibus.Claim.selector) {
        assertEq(logs[i].topics[1], lock);
        // Check secret is in data
        bytes32 emittedSecret = abi.decode(logs[i].data, (bytes32));
        assertEq(emittedSecret, SECRET);
        foundEvent = true;
        break;
      }
    }
    assertTrue(foundEvent, 'Claim event not emitted');
  }

  function test_execute_anyoneCanExecute() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Charlie executes with valid secret
    vm.prank(CHARLIE);
    omnibus.execute(SECRET, alice, bob);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  function test_execute_withNativeAssets() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;

    omnibus.execute(SECRET, alice, bob);

    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, DEFAULT_AMOUNT);
  }

  function test_execute_withERC20Assets() public {
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    uint256 bobRecipientBefore = mockERC20.balanceOf(BOB_RECIPIENT);

    omnibus.execute(SECRET, alice, bob);

    assertEq(mockERC20.balanceOf(BOB_RECIPIENT) - bobRecipientBefore, DEFAULT_AMOUNT);
  }

  function test_execute_withERC721Assets() public {
    // ALICE owns tokens 1, 2, 3 from setUp minting
    uint256 tokenId = 1;
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeERC721Assets(tokenId)
    );
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    assertEq(mockERC721.ownerOf(tokenId), address(omnibus));

    omnibus.execute(SECRET, alice, bob);

    assertEq(mockERC721.ownerOf(tokenId), BOB_RECIPIENT);
  }

  function test_execute_withERC1155Assets() public {
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeERC1155Assets(ERC1155_TOKEN_ID, 100)
    );
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    uint256 bobRecipientBefore = mockERC1155.balanceOf(BOB_RECIPIENT, ERC1155_TOKEN_ID);

    omnibus.execute(SECRET, alice, bob);

    assertEq(mockERC1155.balanceOf(BOB_RECIPIENT, ERC1155_TOKEN_ID) - bobRecipientBefore, 100);
  }

  function test_execute_setsLockStateToSpent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));

    omnibus.execute(SECRET, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  // ============ Revert Cases ============

  function test_execute_revertsWhen_wrongSecret() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    bytes32 wrongSecret = keccak256('wrong');
    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.execute(wrongSecret, alice, bob);
  }

  function test_execute_revertsWhen_termsMismatch() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Modify terms
    Terms memory aliceModified = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAssets(DEFAULT_AMOUNT + 1) // Different amount
    );

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.execute(SECRET, aliceModified, bob);
  }

  function test_execute_revertsWhen_lockNotCommitted() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Only first commit (Free state)
    _commitFor(ALICE, lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.execute(SECRET, alice, bob);
  }

  function test_execute_revertsWhen_lockUnused() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Unused));

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.execute(SECRET, alice, bob);
  }

  function test_execute_revertsWhen_lockFree() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.execute(SECRET, alice, bob);
  }

  function test_execute_revertsWhen_lockSpent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    omnibus.execute(SECRET, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.execute(SECRET, alice, bob);
  }

  function test_execute_revertsWhen_partyDeadlineExpired() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Warp past alice's deadline
    vm.warp(alice.deadline);

    vm.expectRevert(TermsLib.TermsExpired.selector);
    omnibus.execute(SECRET, alice, bob);
  }

  function test_execute_revertsWhen_counterpartyDeadlineExpired() public {
    // Create terms with different deadlines
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 2 days),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      uint64(block.timestamp + 1 days),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );

    _commitBothParties(lock, alice, bob);

    // Warp past bob's deadline but before alice's
    vm.warp(bob.deadline);

    vm.expectRevert(TermsLib.TermsExpired.selector);
    omnibus.execute(SECRET, alice, bob);
  }

  function test_execute_revertsWhen_bothDeadlinesExpired() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Warp past both deadlines
    vm.warp(alice.deadline > bob.deadline ? alice.deadline : bob.deadline);

    vm.expectRevert(TermsLib.TermsExpired.selector);
    omnibus.execute(SECRET, alice, bob);
  }

  function test_execute_revertsWhen_partyNotOnChain() public {
    // Create cross-chain terms where party is on other chain
    Terms memory alice = _makeTerms(
      OTHER_CHAIN_ID, // Alice on other chain
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    // Manually set committed state for testing
    bytes32 hash = omnibus.computeTermsHash(alice, bob);
    omnibus.setLockState(lock, LockState.Committed);
    omnibus.setTermsHash(lock, hash);

    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    omnibus.execute(SECRET, alice, bob);
  }

  function test_execute_revertsWhen_onlyCounterpartyOnChain() public {
    // Same as above - party must be on chain
    Terms memory alice = _makeTerms(
      OTHER_CHAIN_ID, // Alice on other chain
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms(); // Bob on this chain

    bytes32 hash = omnibus.computeTermsHash(alice, bob);
    omnibus.setLockState(lock, LockState.Committed);
    omnibus.setTermsHash(lock, hash);

    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    omnibus.execute(SECRET, alice, bob);
  }

  // ============ Edge Cases ============

  function test_execute_exactDeadlineTimestamp() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Warp to exactly deadline
    vm.warp(alice.deadline);

    vm.expectRevert(TermsLib.TermsExpired.selector);
    omnibus.execute(SECRET, alice, bob);
  }

  function test_execute_oneSecondBeforeDeadline() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Warp to one second before deadline
    vm.warp(alice.deadline - 1);

    omnibus.execute(SECRET, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  // ============ Fuzz Tests ============

  function testFuzz_execute_withValidSecret(bytes32 secret) public {
    vm.assume(secret != bytes32(0));

    bytes32 _lock = omnibus.exposed_generateLock(secret);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, _lock, alice, bob);
    _commitFor(BOB, _lock, bob, alice);

    omnibus.execute(secret, alice, bob);
    assertEq(uint8(omnibus.lockState(_lock)), uint8(LockState.Spent));
  }
}
