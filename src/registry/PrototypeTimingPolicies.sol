// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ProtocolHashing} from '../protocol/ProtocolHashing.sol';
import {TimingPolicy, WrapperMode} from '../protocol/ProtocolTypes.sol';

/// @notice Canonical testnet-only timing assumptions for the deployment prototype.
library PrototypeTimingPolicies {
  uint256 internal constant BASE_SEPOLIA = 84_532;
  uint256 internal constant OP_SEPOLIA = 11_155_420;
  uint256 internal constant POLICY_VERSION = 1;
  uint256 internal constant FINAL_CLAIM_DELAY = 30 minutes;

  function baseSepoliaToOpSepolia() internal pure returns (TimingPolicy memory) {
    return _policy(BASE_SEPOLIA, OP_SEPOLIA);
  }

  function opSepoliaToBaseSepolia() internal pure returns (TimingPolicy memory) {
    return _policy(OP_SEPOLIA, BASE_SEPOLIA);
  }

  function policyId(TimingPolicy memory policy) internal pure returns (bytes32) {
    return ProtocolHashing.timingPolicyId(policy);
  }

  function _policy(uint256 partyChainId, uint256 counterpartyChainId) private pure returns (TimingPolicy memory) {
    return TimingPolicy({
      policyVersion: POLICY_VERSION,
      mode: WrapperMode.CrossChain,
      partyChainId: partyChainId,
      counterpartyChainId: counterpartyChainId,
      partyToCounterpartyDelay: FINAL_CLAIM_DELAY,
      counterpartyToPartyDelay: FINAL_CLAIM_DELAY
    });
  }
}
