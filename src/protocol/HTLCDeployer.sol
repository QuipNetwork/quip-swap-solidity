// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {SideTag} from './ProtocolTypes.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';

/// @title HTLCDeployer
/// @notice Deploys and predicts the deterministic minimal clone for one committed swap side.
/// @dev The wrapper is both the CREATE2 deployer and an explicit salt component. Consequently,
///      two wrappers cannot share an HTLC identity even if every trade input is otherwise equal.
library HTLCDeployer {
  string internal constant HTLC_SALT_DOMAIN = 'InterlockSwapHTLC-v1.1';

  error InvalidHTLCImplementation();

  /// @notice Derives the wrapper-local storage key for one committed trade side.
  function recordKey(bytes32 tradeId, bytes32 lock, SideTag side) internal pure returns (bytes32) {
    return keccak256(abi.encode(tradeId, lock, side));
  }

  /// @notice Derives the canonical salt for one wrapper-controlled trade side.
  function salt(address wrapper, bytes32 tradeId, bytes32 lock, SideTag side) internal pure returns (bytes32) {
    return keccak256(abi.encode(HTLC_SALT_DOMAIN, wrapper, tradeId, lock, side));
  }

  /// @notice Deploys the unique EIP-1167 clone for a trade side.
  /// @dev This function must execute in wrapper context so `address(this)` is both the explicit
  ///      wrapper salt component and the actual CREATE2 deployer used by address prediction.
  function deploy(address implementation, bytes32 tradeId, bytes32 lock, SideTag side) internal returns (address htlc) {
    if (implementation.code.length == 0) revert InvalidHTLCImplementation();
    htlc = LibClone.cloneDeterministic(implementation, salt(address(this), tradeId, lock, side));
  }

  /// @notice Predicts the clone deployed by `wrapper` for a trade side.
  function predict(
    address implementation,
    address wrapper,
    bytes32 tradeId,
    bytes32 lock,
    SideTag side
  ) internal pure returns (address htlc) {
    if (implementation == address(0)) revert InvalidHTLCImplementation();
    htlc = LibClone.predictDeterministicAddress(implementation, salt(wrapper, tradeId, lock, side), wrapper);
  }
}
