// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Ownable} from '@openzeppelin-contracts-5.6.0-rc.1/access/Ownable.sol';
import {Test} from 'forge-std-1.14.0/Test.sol';

import {ITimingPolicyRegistry} from '../../src/interfaces/ITimingPolicyRegistry.sol';
import {ProtocolHashing} from '../../src/protocol/ProtocolHashing.sol';
import {TimingPolicy, WrapperMode} from '../../src/protocol/ProtocolTypes.sol';
import {PrototypeTimingPolicies} from '../../src/registry/PrototypeTimingPolicies.sol';
import {TimingPolicyRegistry} from '../../src/registry/TimingPolicyRegistry.sol';
import {TimingPolicyConsumerHarness} from '../harness/TimingPolicyConsumerHarness.sol';

contract TimingPolicyRegistryTest is Test {
  TimingPolicyRegistry internal registry;
  address internal owner = makeAddr('owner');
  address internal stranger = makeAddr('stranger');

  function setUp() public {
    registry = new TimingPolicyRegistry(owner);
  }

  function test_registerAndResolveCrossChainPolicy() public {
    TimingPolicy memory policy = _crossChainPolicy();
    bytes32 policyId = ProtocolHashing.timingPolicyId(policy);

    vm.prank(owner);
    registry.registerPolicy(policyId, policy);

    assertTrue(registry.isRegistered(policyId));
    _assertPolicyEq(registry.resolvePolicy(policyId), policy);
  }

  function test_registersCanonicalPrototypePoliciesForEitherPartyOrdering() public {
    TimingPolicy memory baseToOp = PrototypeTimingPolicies.baseSepoliaToOpSepolia();
    TimingPolicy memory opToBase = PrototypeTimingPolicies.opSepoliaToBaseSepolia();
    bytes32 baseToOpId = _register(baseToOp);
    bytes32 opToBaseId = _register(opToBase);

    assertTrue(baseToOpId != opToBaseId);
    assertEq(baseToOp.partyChainId, 84_532);
    assertEq(baseToOp.counterpartyChainId, 11_155_420);
    assertEq(opToBase.partyChainId, 11_155_420);
    assertEq(opToBase.counterpartyChainId, 84_532);
    assertEq(registry.finalClaimDelay(baseToOpId, 84_532, 11_155_420), 30 minutes);
    assertEq(registry.finalClaimDelay(baseToOpId, 11_155_420, 84_532), 30 minutes);
    assertEq(registry.finalClaimDelay(opToBaseId, 11_155_420, 84_532), 30 minutes);
    assertEq(registry.finalClaimDelay(opToBaseId, 84_532, 11_155_420), 30 minutes);
  }

  function test_registerEmitsCanonicalPolicy() public {
    TimingPolicy memory policy = _crossChainPolicy();
    bytes32 policyId = ProtocolHashing.timingPolicyId(policy);

    vm.expectEmit(true, true, false, true, address(registry));
    emit ITimingPolicyRegistry.TimingPolicyRegistered(
      policyId,
      policy.policyVersion,
      policy.mode,
      policy.partyChainId,
      policy.counterpartyChainId,
      policy.partyToCounterpartyDelay,
      policy.counterpartyToPartyDelay
    );
    vm.prank(owner);
    registry.registerPolicy(policyId, policy);
  }

  function test_registerIsOwnerOnly() public {
    TimingPolicy memory policy = _crossChainPolicy();
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
    vm.prank(stranger);
    registry.registerPolicy(ProtocolHashing.timingPolicyId(policy), policy);
  }

  function test_registerRejectsIdentifierMismatch() public {
    TimingPolicy memory policy = _crossChainPolicy();
    bytes32 actual = ProtocolHashing.timingPolicyId(policy);
    bytes32 expected = bytes32(uint256(actual) ^ 1);
    vm.expectRevert(abi.encodeWithSelector(ITimingPolicyRegistry.TimingPolicyIdMismatch.selector, expected, actual));
    vm.prank(owner);
    registry.registerPolicy(expected, policy);
  }

  function test_registerRejectsDuplicateIdentifier() public {
    TimingPolicy memory policy = _crossChainPolicy();
    bytes32 policyId = _register(policy);
    vm.expectRevert(abi.encodeWithSelector(ITimingPolicyRegistry.TimingPolicyAlreadyRegistered.selector, policyId));
    vm.prank(owner);
    registry.registerPolicy(policyId, policy);
  }

  function test_mutatedPolicyCannotReuseIdentifier() public {
    TimingPolicy memory original = _crossChainPolicy();
    bytes32 policyId = _register(original);
    TimingPolicy memory mutated = original;
    mutated.partyToCounterpartyDelay += 1;
    bytes32 mutatedId = ProtocolHashing.timingPolicyId(mutated);

    vm.expectRevert(abi.encodeWithSelector(ITimingPolicyRegistry.TimingPolicyIdMismatch.selector, policyId, mutatedId));
    vm.prank(owner);
    registry.registerPolicy(policyId, mutated);
    _assertPolicyEq(registry.resolvePolicy(policyId), _crossChainPolicy());
  }

  function test_resolveRejectsUnknownIdentifier() public {
    bytes32 policyId = keccak256('unknown');
    vm.expectRevert(abi.encodeWithSelector(ITimingPolicyRegistry.TimingPolicyNotRegistered.selector, policyId));
    registry.resolvePolicy(policyId);
  }

  function test_resolveForRouteRequiresExactModeAndOrderedChains() public {
    TimingPolicy memory policy = _crossChainPolicy();
    bytes32 policyId = _register(policy);
    _assertPolicyEq(
      registry.resolvePolicyForRoute(policyId, WrapperMode.CrossChain, policy.partyChainId, policy.counterpartyChainId),
      policy
    );

    vm.expectRevert(abi.encodeWithSelector(ITimingPolicyRegistry.TimingPolicyRouteMismatch.selector, policyId));
    registry.resolvePolicyForRoute(policyId, WrapperMode.CrossChain, policy.counterpartyChainId, policy.partyChainId);
    vm.expectRevert(abi.encodeWithSelector(ITimingPolicyRegistry.TimingPolicyRouteMismatch.selector, policyId));
    registry.resolvePolicyForRoute(policyId, WrapperMode.SameChain, policy.partyChainId, policy.counterpartyChainId);
  }

  function test_finalClaimDelayIsDirectionalAndHasNoTimeGate() public {
    TimingPolicy memory policy = _crossChainPolicy();
    bytes32 policyId = _register(policy);
    assertEq(
      registry.finalClaimDelay(policyId, policy.partyChainId, policy.counterpartyChainId),
      policy.partyToCounterpartyDelay
    );
    assertEq(
      registry.finalClaimDelay(policyId, policy.counterpartyChainId, policy.partyChainId),
      policy.counterpartyToPartyDelay
    );

    vm.warp(type(uint64).max);
    assertEq(
      registry.finalClaimDelay(policyId, policy.partyChainId, policy.counterpartyChainId),
      policy.partyToCounterpartyDelay
    );
  }

  function test_finalClaimDelayRejectsUnrelatedRoute() public {
    TimingPolicy memory policy = _crossChainPolicy();
    bytes32 policyId = _register(policy);
    vm.expectRevert(abi.encodeWithSelector(ITimingPolicyRegistry.TimingPolicyRouteMismatch.selector, policyId));
    registry.finalClaimDelay(policyId, policy.partyChainId, 99_999);
  }

  function test_registerSameChainPolicyWithCanonicalZeroDelays() public {
    TimingPolicy memory policy = TimingPolicy({
      policyVersion: 1,
      mode: WrapperMode.SameChain,
      partyChainId: 31_337,
      counterpartyChainId: 31_337,
      partyToCounterpartyDelay: 0,
      counterpartyToPartyDelay: 0
    });
    bytes32 policyId = _register(policy);
    _assertPolicyEq(registry.resolvePolicy(policyId), policy);
    assertEq(registry.finalClaimDelay(policyId, 31_337, 31_337), 0);
  }

  function test_rejectsInvalidPolicyShapes() public {
    TimingPolicy memory policy = _crossChainPolicy();
    policy.policyVersion = 0;
    _expectInvalid(policy);
    policy = _crossChainPolicy();
    policy.partyChainId = 0;
    _expectInvalid(policy);
    policy = _crossChainPolicy();
    policy.counterpartyChainId = policy.partyChainId;
    _expectInvalid(policy);
    policy = _crossChainPolicy();
    policy.partyToCounterpartyDelay = 0;
    _expectInvalid(policy);

    policy = TimingPolicy({
      policyVersion: 1,
      mode: WrapperMode.SameChain,
      partyChainId: 1,
      counterpartyChainId: 2,
      partyToCounterpartyDelay: 0,
      counterpartyToPartyDelay: 0
    });
    _expectInvalid(policy);
    policy.counterpartyChainId = 1;
    policy.counterpartyToPartyDelay = 1;
    _expectInvalid(policy);
  }

  function test_pairedRegistriesResolveIdenticalImmutableBytes() public {
    TimingPolicyRegistry other = new TimingPolicyRegistry(owner);
    TimingPolicy memory policy = _crossChainPolicy();
    bytes32 policyId = ProtocolHashing.timingPolicyId(policy);
    vm.startPrank(owner);
    registry.registerPolicy(policyId, policy);
    other.registerPolicy(policyId, policy);
    vm.stopPrank();

    TimingPolicyConsumerHarness leftWrapper =
      new TimingPolicyConsumerHarness(registry, WrapperMode.CrossChain, 31_337, 31_338);
    TimingPolicyConsumerHarness rightWrapper =
      new TimingPolicyConsumerHarness(other, WrapperMode.CrossChain, 31_337, 31_338);
    TimingPolicy memory left = leftWrapper.resolvePolicy(policyId);
    TimingPolicy memory right = rightWrapper.resolvePolicy(policyId);
    assertEq(keccak256(abi.encode(left)), keccak256(abi.encode(right)));
    assertEq(ProtocolHashing.timingPolicyId(left), policyId);
    assertEq(ProtocolHashing.timingPolicyId(right), policyId);
  }

  function test_pairedRegistriesWithDifferentPoliciesRejectTheOtherSignedIdentifier() public {
    TimingPolicyRegistry other = new TimingPolicyRegistry(owner);
    TimingPolicy memory expected = _crossChainPolicy();
    bytes32 expectedId = _register(expected);
    TimingPolicy memory different = _crossChainPolicy();
    different.counterpartyToPartyDelay += 1;
    bytes32 differentId = ProtocolHashing.timingPolicyId(different);
    vm.prank(owner);
    other.registerPolicy(differentId, different);

    _assertPolicyEq(
      registry.resolvePolicyForRoute(
        expectedId, WrapperMode.CrossChain, expected.partyChainId, expected.counterpartyChainId
      ),
      expected
    );
    vm.expectRevert(abi.encodeWithSelector(ITimingPolicyRegistry.TimingPolicyNotRegistered.selector, expectedId));
    other.resolvePolicyForRoute(expectedId, WrapperMode.CrossChain, expected.partyChainId, expected.counterpartyChainId);
  }

  function _crossChainPolicy() internal pure returns (TimingPolicy memory) {
    return TimingPolicy({
      policyVersion: 1,
      mode: WrapperMode.CrossChain,
      partyChainId: 31_337,
      counterpartyChainId: 31_338,
      partyToCounterpartyDelay: 120,
      counterpartyToPartyDelay: 180
    });
  }

  function _register(TimingPolicy memory policy) internal returns (bytes32 policyId) {
    policyId = ProtocolHashing.timingPolicyId(policy);
    vm.prank(owner);
    registry.registerPolicy(policyId, policy);
  }

  function _expectInvalid(TimingPolicy memory policy) internal {
    vm.expectRevert(ITimingPolicyRegistry.InvalidTimingPolicy.selector);
    vm.prank(owner);
    registry.registerPolicy(ProtocolHashing.timingPolicyId(policy), policy);
  }

  function _assertPolicyEq(TimingPolicy memory actual, TimingPolicy memory expected) internal pure {
    assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(expected)));
  }
}
