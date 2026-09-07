// SPDX-License-Identifier: UNLICENSE
// Pin the compiler version used for these encodings and contract semantics.
pragma solidity 0.8.33;

// Import canonical party and counterparty side tags.
import {SideTag} from './ProtocolTypes.sol';
// Import EIP-1167 clone creation and deterministic address prediction.
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';

/// @title HTLCDeployer
/// @notice Deploys and predicts the deterministic minimal clone for one committed swap side.
/// @dev The wrapper is both the CREATE2 deployer and an explicit salt component. Consequently,
///      two wrappers cannot share an HTLC identity even if every trade input is otherwise equal.
library HTLCDeployer {
  // Keep clone salts distinct from every other protocol hash domain.
  string internal constant HTLC_SALT_DOMAIN = 'InterlockSwapHTLC-v1.1';

  // The clone implementation address is invalid for this operation.
  error InvalidHTLCImplementation();

  /// @notice Derives the wrapper-local storage key for one committed trade side.
  function recordKey(bytes32 tradeId, bytes32 lock, SideTag side) internal pure returns (bytes32) {
    // Hash the complete local-leg identity with unambiguous ABI encoding.
    return keccak256(abi.encode(tradeId, lock, side));
  }

  /// @notice Derives the canonical salt for one wrapper-controlled trade side.
  function salt(address wrapper, bytes32 tradeId, bytes32 lock, SideTag side) internal pure returns (bytes32) {
    // Bind the salt to this wrapper, trade, settlement lock, and side.
    return keccak256(abi.encode(HTLC_SALT_DOMAIN, wrapper, tradeId, lock, side));
  }

  /// @notice Deploys the unique EIP-1167 clone for a trade side.
  /// @dev This function must execute in wrapper context so `address(this)` is both the explicit
  ///      wrapper salt component and the actual CREATE2 deployer used by address prediction.
  function deploy(address implementation, bytes32 tradeId, bytes32 lock, SideTag side) internal returns (address htlc) {
    // The clone implementation address is invalid for this operation.
    if (implementation.code.length == 0) revert InvalidHTLCImplementation();

    // Deploy the minimal proxy with a salt unique to this wrapper and committed side.
    htlc = LibClone.cloneDeterministic(implementation, salt(address(this), tradeId, lock, side));
  }

  /// @notice Predicts the clone deployed by `wrapper` for a trade side.
  function predict(
    // Minimal-proxy implementation used for deployment or prediction.
    address implementation,
    // Wrapper address used as deployment and salt scope.
    address wrapper,
    // Hash of the complete ordered terms.
    bytes32 tradeId,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Ordered side whose assets or state this operation addresses.
    SideTag side
    // Compute and return the predicted clone address without deploying code.
  ) internal pure returns (address htlc) {
    // The clone implementation address is invalid for this operation.
    if (implementation == address(0)) revert InvalidHTLCImplementation();

    // Reproduce CREATE2 address derivation using the same implementation, salt, and wrapper.
    htlc = LibClone.predictDeterministicAddress(implementation, salt(wrapper, tradeId, lock, side), wrapper);
  }
}
