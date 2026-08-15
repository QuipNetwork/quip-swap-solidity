// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PQIdentityRegistry} from './PQIdentityRegistry.sol';
import {DelegationPolicy, SideTerms} from './ProtocolTypes.sol';

library AuthorizationSubmitter {
  error InvalidTransportSubmitter();

  function derive(
    SideTerms memory side,
    PQIdentityRegistry registry,
    address transportCaller
  ) internal view returns (address submitter, uint256 keyVersion) {
    if (side.delegationPolicy == DelegationPolicy.NotAllowed) {
      if (transportCaller != side.principal) revert InvalidTransportSubmitter();
      return (transportCaller, side.principalKeyVersion);
    }
    if (side.delegationPolicy == DelegationPolicy.SpecificDelegate) {
      if (transportCaller == side.principal) return (transportCaller, side.principalKeyVersion);
      if (transportCaller == side.delegate) {
        registry.activeKey(side.delegate, side.delegateKeyVersion);
        return (transportCaller, side.delegateKeyVersion);
      }
      revert InvalidTransportSubmitter();
    }
    if (transportCaller == address(0)) revert InvalidTransportSubmitter();
    return (transportCaller, 0);
  }
}
