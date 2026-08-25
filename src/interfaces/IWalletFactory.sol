// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.33;

/// @title IWalletFactory
/// @notice minimal consumer-side view of the quip WalletFactory registry — just
/// enough surface for Omnibus to test factory membership on the wallet route.
/// The factory lives behind an ERC-1967 proxy whose address is its permanent
/// identity, so a baked-in reference survives factory upgrades
interface IWalletFactory {
  /// @notice the vaultId (global CREATE3 salt) a wallet was deployed under
  /// @dev bytes32(0) means "not deployed by this factory" — the membership
  /// discriminator. The factory writes this mapping exactly once, at wallet
  /// deployment, so membership can never be revoked or reassigned
  /// @param wallet the address to look up
  /// @return vaultId the wallet's vaultId, or bytes32(0) if not factory-deployed
  function vaultIdOf(address wallet) external view returns (bytes32 vaultId);
}
