// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Ownable, Ownable2Step} from '@openzeppelin-contracts-5.6.0-rc.1/access/Ownable2Step.sol';

import {ITimingPolicyRegistry} from '../interfaces/ITimingPolicyRegistry.sol';
import {ProtocolHashing} from '../protocol/ProtocolHashing.sol';
import {TimingPolicy, WrapperMode} from '../protocol/ProtocolTypes.sol';

contract TimingPolicyRegistry is ITimingPolicyRegistry, Ownable2Step {
  mapping(bytes32 policyId => TimingPolicy policy) private _policies;
  mapping(bytes32 policyId => bool registered) private _registered;

  constructor(address initialOwner) Ownable(initialOwner) {}

  function registerPolicy(bytes32 expectedPolicyId, TimingPolicy calldata policy) external onlyOwner {
    _validatePolicy(policy);
    bytes32 actualPolicyId = ProtocolHashing.timingPolicyId(policy);
    if (actualPolicyId != expectedPolicyId) revert TimingPolicyIdMismatch(expectedPolicyId, actualPolicyId);
    if (_registered[expectedPolicyId]) revert TimingPolicyAlreadyRegistered(expectedPolicyId);

    _policies[expectedPolicyId] = policy;
    _registered[expectedPolicyId] = true;
    emit TimingPolicyRegistered(
      expectedPolicyId,
      policy.policyVersion,
      policy.mode,
      policy.partyChainId,
      policy.counterpartyChainId,
      policy.partyToCounterpartyDelay,
      policy.counterpartyToPartyDelay
    );
  }

  function isRegistered(bytes32 policyId) external view returns (bool) {
    return _registered[policyId];
  }

  function resolvePolicy(bytes32 policyId) public view returns (TimingPolicy memory policy) {
    if (!_registered[policyId]) revert TimingPolicyNotRegistered(policyId);
    policy = _policies[policyId];
    bytes32 actualPolicyId = ProtocolHashing.timingPolicyId(policy);
    if (actualPolicyId != policyId) revert TimingPolicyIdMismatch(policyId, actualPolicyId);
  }

  function resolvePolicyForRoute(
    bytes32 policyId,
    WrapperMode expectedMode,
    uint256 partyChainId,
    uint256 counterpartyChainId
  ) external view returns (TimingPolicy memory policy) {
    policy = resolvePolicy(policyId);
    if (
      policy.mode != expectedMode || policy.partyChainId != partyChainId
        || policy.counterpartyChainId != counterpartyChainId
    ) revert TimingPolicyRouteMismatch(policyId);
  }

  function finalClaimDelay(
    bytes32 policyId,
    uint256 fromChainId,
    uint256 toChainId
  ) external view returns (uint256 delay) {
    TimingPolicy memory policy = resolvePolicy(policyId);
    if (fromChainId == policy.partyChainId && toChainId == policy.counterpartyChainId) {
      return policy.partyToCounterpartyDelay;
    }
    if (fromChainId == policy.counterpartyChainId && toChainId == policy.partyChainId) {
      return policy.counterpartyToPartyDelay;
    }
    revert TimingPolicyRouteMismatch(policyId);
  }

  function _validatePolicy(TimingPolicy calldata policy) private pure {
    if (policy.policyVersion == 0 || policy.partyChainId == 0 || policy.counterpartyChainId == 0) {
      revert InvalidTimingPolicy();
    }
    if (policy.mode == WrapperMode.SameChain) {
      if (
        policy.partyChainId != policy.counterpartyChainId || policy.partyToCounterpartyDelay != 0
          || policy.counterpartyToPartyDelay != 0
      ) revert InvalidTimingPolicy();
    } else if (
      policy.partyChainId == policy.counterpartyChainId || policy.partyToCounterpartyDelay == 0
        || policy.counterpartyToPartyDelay == 0
    ) {
      revert InvalidTimingPolicy();
    }
  }
}
