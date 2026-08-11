// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ProgressionGate} from '../../src/ProgressionGate.sol';
import {ProtocolHashing} from '../../src/ProtocolHashing.sol';
import {DelegationPolicy, ProtocolTerms} from '../../src/ProtocolTypes.sol';
import {ProgressionGateHarness} from '../harness/ProgressionGateHarness.sol';
import {Test} from 'forge-std-1.14.0/Test.sol';

contract ProgressionGateTest is Test {
  bytes32 internal constant SECRET = keccak256('bob-commit-secret');
  ProgressionGateHarness internal harness;

  function setUp() public {
    harness = new ProgressionGateHarness();
  }

  function test_crossChainPartyNeedsNoSecretAndCounterpartyRequiresExactSecret() public view {
    ProtocolTerms memory terms = _crossChainTerms(SECRET, keccak256('run-a'));
    harness.validate(terms, true, bytes32(0));
    harness.validate(terms, false, SECRET);
  }

  function test_crossChainCounterpartyRejectsAbsentAndIncorrectSecret() public {
    ProtocolTerms memory terms = _crossChainTerms(SECRET, keccak256('run-a'));
    vm.expectRevert(ProgressionGate.MissingBobCommitSecret.selector);
    harness.validate(terms, false, bytes32(0));
    vm.expectRevert(ProgressionGate.InvalidBobCommitSecret.selector);
    harness.validate(terms, false, keccak256('wrong'));
  }

  function test_secretFromAnotherTradeCannotOpenThisTrade() public {
    bytes32 otherSecret = keccak256('other-secret');
    ProtocolTerms memory other = _crossChainTerms(otherSecret, keccak256('run-b'));
    vm.expectRevert(ProgressionGate.InvalidBobCommitSecret.selector);
    harness.validate(other, false, SECRET);
  }

  function test_reusedSecretOpensEveryTradeThatDeliberatelyUsesIt() public view {
    ProtocolTerms memory first = _crossChainTerms(SECRET, keccak256('run-a'));
    ProtocolTerms memory second = _crossChainTerms(SECRET, keccak256('run-b'));
    assertNotEq(ProtocolHashing.gateContextId(first), ProtocolHashing.gateContextId(second));
    assertNotEq(first.counterpartySide.commitLock, second.counterpartySide.commitLock);

    // Trade binding prevents lock substitution, not unsafe preimage reuse.
    harness.validate(first, false, SECRET);
    harness.validate(second, false, SECRET);
  }

  function test_prematureDisclosureMakesCounterpartyGateImmediatelyUsable() public view {
    ProtocolTerms memory terms = _crossChainTerms(SECRET, keccak256('premature-disclosure'));
    // ProgressionGate is intentionally stateless: finality is enforced by withholding this preimage off-chain.
    harness.validate(terms, false, SECRET);
  }

  function test_partyCommitRejectsPrematureOrExtraneousProgressionSecret() public {
    ProtocolTerms memory terms = _crossChainTerms(SECRET, keccak256('run-a'));
    vm.expectRevert(ProgressionGate.UnexpectedBobCommitSecret.selector);
    harness.validate(terms, true, SECRET);
  }

  function test_sameChainNeverAcceptsProgressionSecretOnEitherCommit() public {
    ProtocolTerms memory terms = _sameChainTerms();
    harness.validate(terms, true, bytes32(0));
    harness.validate(terms, false, bytes32(0));
    vm.expectRevert(ProgressionGate.UnexpectedBobCommitSecret.selector);
    harness.validate(terms, true, SECRET);
    vm.expectRevert(ProgressionGate.UnexpectedBobCommitSecret.selector);
    harness.validate(terms, false, SECRET);
  }

  function test_rejectsNoncanonicalProgressionLockShapes() public {
    ProtocolTerms memory terms = _sameChainTerms();
    terms.partySide.commitLock = bytes32(uint256(1));
    vm.expectRevert(ProgressionGate.InvalidProgressionTerms.selector);
    harness.validate(terms, true, bytes32(0));

    terms = _crossChainTerms(SECRET, keccak256('run-a'));
    terms.counterpartySide.commitLock = bytes32(0);
    vm.expectRevert(ProgressionGate.InvalidProgressionTerms.selector);
    harness.validate(terms, false, SECRET);
  }

  function test_gateContextProjectionRemovesOnlyCommitLockCircularity() public pure {
    ProtocolTerms memory terms = _baseTerms(1, 2, keccak256('run-a'));
    bytes32 contextBefore = ProtocolHashing.gateContextId(terms);
    terms.counterpartySide.commitLock = ProtocolHashing.commitLock(contextBefore, SECRET);
    assertEq(ProtocolHashing.gateContextId(terms), contextBefore);
    assertNotEq(ProtocolHashing.tradeId(terms), ProtocolHashing.tradeId(ProtocolHashing.gateTerms(terms)));
  }

  function test_gateIsIndependentOfEveryDelegationPolicy() public view {
    for (uint8 i; i <= uint8(DelegationPolicy.SpecificDelegate); ++i) {
      ProtocolTerms memory terms = _baseTerms(1, 2, bytes32(uint256(i + 1)));
      terms.counterpartySide.delegationPolicy = DelegationPolicy(i);
      terms.counterpartySide.commitLock = ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), SECRET);
      harness.validate(terms, false, SECRET);
    }
  }

  function _crossChainTerms(bytes32 secret, bytes32 runNonce) internal pure returns (ProtocolTerms memory terms) {
    terms = _baseTerms(1, 2, runNonce);
    terms.counterpartySide.commitLock = ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), secret);
  }

  function _sameChainTerms() internal pure returns (ProtocolTerms memory) {
    return _baseTerms(1, 1, keccak256('same-chain'));
  }

  function _baseTerms(
    uint256 partyChain,
    uint256 counterpartyChain,
    bytes32 runNonce
  ) internal pure returns (ProtocolTerms memory terms) {
    terms.timingPolicyId = keccak256('policy');
    terms.partySide.chainId = partyChain;
    terms.partySide.principal = address(0xA11CE);
    terms.partySide.sideNonce = runNonce;
    terms.counterpartySide.chainId = counterpartyChain;
    terms.counterpartySide.principal = address(0xB0B);
    terms.counterpartySide.sideNonce = keccak256(abi.encode(runNonce));
  }
}
