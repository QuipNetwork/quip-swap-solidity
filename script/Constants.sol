// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

/**
 * @title Constants
 * @dev Shared deployment constants used across the deploy/verify scripts.
 *      Single source of truth so DeployOmnibus and VerifyOmnibus can never
 *      drift on the CREATE3 salt (which would change the deterministic address).
 */
library Constants {
  /// @notice CREATE3 salt for the Omnibus singleton. The deployed address is a
  ///         function of (Deployer, salt), so this value is what pins the
  ///         cross-chain Omnibus address. Bump only for an intentional redeploy.
  ///         V2.0: permissionless commit with multi-scheme payload authentication
  ///         (matches Omnibus.VERSION == 2); the V1.0 Omnibus persists on testnets.
  bytes32 internal constant OMNIBUS_SALT = keccak256('QUIP:Omnibus:V2.0');

  /// @notice CREATE3 salt for the stateful SHRINCS ERC-7913 verifier singleton.
  ///         Deployed BEFORE Omnibus on each chain — DeployOmnibus predicts this
  ///         verifier's address from the salt and trusts it at construction.
  bytes32 internal constant SHRINCS_VERIFIER_V1_SALT = keccak256('QUIP:ShrincsVerifier:V1.0');
}
