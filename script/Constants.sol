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

  /// @notice The canonical ShrincsVerifier singleton — deployed and OWNED by
  ///         hashsigs-solidity (its DeployShrincsVerifier script; salt lives
  ///         there). This repo only consumes the published (address, codehash)
  ///         pair from hashsigs' RELEASES.md; DeployOmnibus pins BOTH before
  ///         trusting. A verifier release bumps both constants together in one
  ///         reviewed diff. If cross-chain address uniformity ever breaks, these
  ///         become a chainid-keyed table — still no env vars.
  /// TODO(QUI-781): pre-release values from hashsigs' RELEASES.md v1 rehearsal
  /// (rev 7c75cc2 + script, production profile). Re-verify against the registry
  /// after hashsigs' first canonical per-chain deploy.
  address internal constant SHRINCS_VERIFIER = 0x560Ea50c83AB3952587fa3C7b9250c045cfA1252;

  /// @notice `cast codehash` of the canonical deployment (runtime codehash).
  ///         Chain-invariant because the verifier has no immutables. The compare
  ///         in DeployOmnibus subsumes existence: a nonexistent account hashes
  ///         to 0x0 and a code-less one to keccak('') — both fail.
  bytes32 internal constant SHRINCS_VERIFIER_CODEHASH =
    0x8553890af0b7136ccf8993d2d691c492618150ee85f028892f285ccb6682a5ff;
}
