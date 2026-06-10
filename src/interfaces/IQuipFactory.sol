// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

/// @title IQuipFactory
/// @notice minimal view surface of the QuipFactory wallet registry consumed by Omnibus
interface IQuipFactory {
  /// @notice returns the vaultId of a wallet
  /// @dev non-zero iff the wallet was deployed by the factory
  /// @param wallet the wallet address
  /// @return vaultId the wallet's vaultId (bytes32(0) if not factory-deployed)
  function vaultIdOf(address wallet) external view returns (bytes32 vaultId);
}
