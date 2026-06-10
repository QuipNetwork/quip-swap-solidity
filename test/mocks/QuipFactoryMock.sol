// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.33;

/// @title QuipFactory Mock
/// @dev test double for QuipFactory; mirrors the registry mappings used to verify
/// that a caller is a factory-deployed QuipWallet (`vaultIdOf[wallet] != bytes32(0)`),
/// with setters to arrange state. Note this mock is maintained by hand and may drift
/// out of sync if QuipFactory's registry layout or semantics change
contract QuipFactoryMock {
  /// @notice vaultId => wallet address (mirrors QuipFactory.wallets)
  mapping(bytes32 vaultId => address wallet) public wallets;

  /// @notice wallet address => vaultId (mirrors QuipFactory.vaultIdOf);
  /// non-zero iff the wallet is "deployed by this factory"
  mapping(address wallet => bytes32 vaultId) public vaultIdOf;

  /// @notice wallet address => current classical owner (mirrors QuipFactory.walletOwner)
  mapping(address wallet => address owner) public walletOwner;

  /// @notice registers `wallet` as if it were deployed by the factory,
  /// wiring all three mappings consistently
  function registerWallet(address wallet, bytes32 vaultId, address owner) external {
    wallets[vaultId] = wallet;
    vaultIdOf[wallet] = vaultId;
    walletOwner[wallet] = owner;
  }

  /// @notice removes a wallet from the registry (the real factory never does
  /// this — useful for testing the negative path)
  function unregisterWallet(address wallet) external {
    bytes32 vaultId = vaultIdOf[wallet];
    delete wallets[vaultId];
    delete vaultIdOf[wallet];
    delete walletOwner[wallet];
  }

  function setWallet(bytes32 vaultId, address wallet) external {
    wallets[vaultId] = wallet;
  }

  function setVaultIdOf(address wallet, bytes32 vaultId) external {
    vaultIdOf[wallet] = vaultId;
  }

  function setWalletOwner(address wallet, address owner) external {
    walletOwner[wallet] = owner;
  }

  function getWallet(bytes32 vaultId) external view returns (address) {
    return wallets[vaultId];
  }

  function getVaultIdOf(address wallet) external view returns (bytes32) {
    return vaultIdOf[wallet];
  }

  function getWalletOwner(address wallet) external view returns (address) {
    return walletOwner[wallet];
  }
}
