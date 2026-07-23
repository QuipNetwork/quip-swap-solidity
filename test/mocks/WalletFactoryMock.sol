// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IWalletFactory} from '../../src/interfaces/IWalletFactory.sol';

/// @title WalletFactory Mock
/// @dev settable registry test double: `vaultIdOf` returns whatever a test
/// registered via `setWallet` (bytes32(0) — "not factory-deployed" — for
/// everyone else). Conditional behavior (reverts) lives in the tests via
/// vm.mockCallRevert. Kept as a deployable contract ONLY because the SDK
/// integration suite deploys it to Anvil, where forge cheatcodes do not exist
/// (mirrors VerifierMock).
contract WalletFactoryMock is IWalletFactory {
  mapping(address wallet => bytes32 vaultId) public vaultIdOf;

  function setWallet(address wallet, bytes32 vaultId) external {
    vaultIdOf[wallet] = vaultId;
  }
}
