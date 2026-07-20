// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {CREATE3} from 'solady-0.1.26/utils/CREATE3.sol';

/**
 * @title Constants
 * @dev Shared deployment constants used across the deploy/verify scripts.
 *      Single source of truth so DeployOmnibus and VerifyOmnibus can never
 *      drift on the salt math (which would change the deterministic address).
 *
 *      Omnibus deploys through the canonical CreateX factory via CREATE3, so
 *      its address is a function of (CreateX, deployer EOA, salt) — identical
 *      on every chain provided the SAME ops EOA deploys, and independent of
 *      constructor args. The salt is CreateX-permissioned: only that EOA can
 *      ever claim the address on any chain (no CREATE3 address-squatting).
 */
library Constants {
  /// @notice The canonical CreateX factory, pre-deployed at this address on
  ///         essentially every EVM chain.
  address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

  /// @notice Version entropy for the Omnibus salt (last 11 bytes of the
  ///         permissioned salt). Bump only for an intentional redeploy.
  ///         Semver convention: prerelease salts (-alpha.N/-beta.N/-rc.N) are
  ///         testnet deploys; the bare release (v1.0.0) is reserved for
  ///         mainnet. Each (EOA, entropy) pair maps to a distinct,
  ///         permanently-consumed address.
  bytes11 internal constant OMNIBUS_SALT_ENTROPY = bytes11(keccak256('QUIP:Omnibus:v1.0.0-alpha.1'));

  /// @notice The raw CreateX salt for the Omnibus singleton, permissioned to
  ///         `deployer`: 20-byte EOA ‖ 0x00 (no cross-chain redeploy
  ///         protection — the address must be claimable on every chain) ‖
  ///         11-byte version entropy.
  function omnibusSalt(address deployer) internal pure returns (bytes32) {
    return bytes32(abi.encodePacked(deployer, hex'00', OMNIBUS_SALT_ENTROPY));
  }

  /// @notice The salt CreateX actually feeds to CREATE3. For a sender-prefixed
  ///         salt with the 0x00 flag byte, CreateX takes the
  ///         SenderBytes.MsgSender + RedeployProtectionFlag.False path:
  ///         `keccak256(abi.encodePacked(bytes32(uint256(uint160(sender))), salt))`.
  function guardedSalt(address deployer) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), omnibusSalt(deployer)));
  }

  /// @notice Predicts the Omnibus address for a given deployer EOA — pure
  ///         offline math. CreateX's CREATE3 proxy is the standard one solady
  ///         uses, so solady's predictor applies with CreateX as the deployer.
  function predictOmnibus(address deployer) internal pure returns (address) {
    return CREATE3.predictDeterministicAddress(guardedSalt(deployer), CREATEX);
  }
}
