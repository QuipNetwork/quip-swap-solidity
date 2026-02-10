// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Quip} from '../../src/Quip.sol';

/// @title Quip Harness
/// @dev Exposes internal functions of Quip for testing
contract QuipHarness is Quip {
  /// @notice Exposes _verifyKey
  function exposed_verifyKey(bytes calldata key) external view {
    _verifyKey(key);
  }

  /// @notice Exposes _onlyPortal
  function exposed_onlyPortal() external view {
    _onlyPortal();
  }

  /// @notice Exposes _enforcePortalCaller
  function exposed_enforcePortalCaller() external view {
    _enforcePortalCaller();
  }

  /// @notice Allows direct setting of lock for testing _verifyKey
  function setLock(bytes32 _lock) external {
    lock = _lock;
  }

  /// @notice Allows direct setting of termsDigest for testing
  function setTermsDigest(bytes32 _termsDigest) external {
    termsDigest = _termsDigest;
  }
}
