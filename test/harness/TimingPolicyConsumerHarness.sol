// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ITimingPolicyRegistry} from '../../src/interfaces/ITimingPolicyRegistry.sol';
import {TimingPolicy, WrapperMode} from '../../src/protocol/ProtocolTypes.sol';

contract TimingPolicyConsumerHarness {
  ITimingPolicyRegistry public immutable registry;
  WrapperMode public immutable mode;
  uint256 public immutable partyChainId;
  uint256 public immutable counterpartyChainId;

  constructor(ITimingPolicyRegistry registry_, WrapperMode mode_, uint256 partyChainId_, uint256 counterpartyChainId_) {
    registry = registry_;
    mode = mode_;
    partyChainId = partyChainId_;
    counterpartyChainId = counterpartyChainId_;
  }

  function resolvePolicy(bytes32 policyId) external view returns (TimingPolicy memory) {
    return registry.resolvePolicyForRoute(policyId, mode, partyChainId, counterpartyChainId);
  }
}
