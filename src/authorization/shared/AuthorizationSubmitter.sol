// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {DelegationPolicy, SideTerms} from '../../protocol/ProtocolTypes.sol';

/// @notice Minimal key lookup used to validate a specific direct delegate version.
interface IActiveKeyRegistry {
  /// @notice Returns the active PQ key only when the requested version is current.
  function activeKey(address eoa, uint256 version) external view returns (bytes memory);
}

/// @title AuthorizationSubmitter
/// @notice Derives the authenticated transport submitter under a side delegation policy.
/// @dev Permissionless transport authenticates no registered identity and therefore returns key version zero.
library AuthorizationSubmitter {
  error InvalidTransportSubmitter();

  /// @notice Validates the transport caller and returns the submitter identity recorded in evidence.
  function derive(
    SideTerms memory side,
    IActiveKeyRegistry registry,
    address transportCaller
  ) internal view returns (address submitter, uint256 keyVersion) {
    if (side.delegationPolicy == DelegationPolicy.NotAllowed) {
      // No relay is allowed: transaction transport must be the principal.
      if (transportCaller != side.principal) revert InvalidTransportSubmitter();
      return (transportCaller, side.principalKeyVersion);
    }
    if (side.delegationPolicy == DelegationPolicy.SpecificDelegate) {
      // Principal may self-submit; otherwise accept only the named, current delegate.
      if (transportCaller == side.principal) return (transportCaller, side.principalKeyVersion);
      if (transportCaller == side.delegate) {
        // Lookup is used as validation and reverts for an inactive or stale delegate.
        registry.activeKey(side.delegate, side.delegateKeyVersion);
        return (transportCaller, side.delegateKeyVersion);
      }
      revert InvalidTransportSubmitter();
    }
    // Permissionless transport accepts any nonzero caller without key attribution.
    if (transportCaller == address(0)) revert InvalidTransportSubmitter();
    return (transportCaller, 0);
  }
}
