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
      return (side.principal, side.principalKeyVersion);
    }
    if (side.delegationPolicy == DelegationPolicy.SpecificDelegate) {
      if (transportCaller != side.delegate) revert InvalidTransportSubmitter();
      registry.activeKey(side.delegate, side.delegateKeyVersion);
      return (side.delegate, side.delegateKeyVersion);
    }
    if (transportCaller == address(0)) revert InvalidTransportSubmitter();
    return (transportCaller, 0);
  }
}
