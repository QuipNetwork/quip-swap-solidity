// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

/**
 * @title ICreateX
 * @dev Thin interface to the canonical CreateX factory
 *      (https://github.com/pcaversaccio/createx), pre-deployed at
 *      `Constants.CREATEX` on essentially every EVM chain. Only the two
 *      functions the deploy scripts need are declared — deployment is a
 *      script/-only concern, so the full dependency is not vendored.
 *
 *      NOTE on salts: CreateX guards every salt before use. The scripts use
 *      the permissioned form (first 20 bytes = msg.sender, byte 20 = 0x00),
 *      so only the ops EOA can claim the derived address on any chain; see
 *      `Constants.omnibusSalt` / `Constants.guardedSalt` for the exact math.
 */
interface ICreateX {
  /// @notice Deploys `initCode` via CREATE3 using the guarded form of `salt`.
  /// @dev Reverts if the salt's sender prefix does not match `msg.sender`.
  function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);

  /// @notice Computes the CREATE3 address for an ALREADY-GUARDED salt.
  function computeCreate3Address(bytes32 salt) external view returns (address);
}
