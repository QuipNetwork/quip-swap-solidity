// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {TimingPolicy, WrapperMode} from '../ProtocolTypes.sol';

interface ITimingPolicyRegistry {
  error InvalidTimingPolicy();
  error TimingPolicyIdMismatch(bytes32 expected, bytes32 actual);
  error TimingPolicyAlreadyRegistered(bytes32 policyId);
  error TimingPolicyNotRegistered(bytes32 policyId);
  error TimingPolicyRouteMismatch(bytes32 policyId);

  event TimingPolicyRegistered(
    bytes32 indexed policyId,
    uint256 indexed policyVersion,
    WrapperMode mode,
    uint256 partyChainId,
    uint256 counterpartyChainId,
    uint256 partyToCounterpartyDelay,
    uint256 counterpartyToPartyDelay
  );

  function registerPolicy(bytes32 expectedPolicyId, TimingPolicy calldata policy) external;

  function isRegistered(bytes32 policyId) external view returns (bool);

  function resolvePolicy(bytes32 policyId) external view returns (TimingPolicy memory policy);

  function resolvePolicyForRoute(
    bytes32 policyId,
    WrapperMode mode,
    uint256 partyChainId,
    uint256 counterpartyChainId
  ) external view returns (TimingPolicy memory policy);

  function finalClaimDelay(
    bytes32 policyId,
    uint256 fromChainId,
    uint256 toChainId
  ) external view returns (uint256 delay);
}
