// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Quip} from '../../src/Quip.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title Quip Harness
/// @dev Exposes internal functions of Quip for testing
contract QuipHarness is Quip {
  /// @notice Exposes _verifySignature
  function exposed_verifySignature(WOTSPlus.WinternitzElements calldata signature) external view {
    _verifySignature(signature);
  }

  /// @notice Exposes _onlyPortal
  function exposed_onlyPortal() external view {
    _onlyPortal();
  }

  /// @notice Allows direct setting of pqOwner for testing
  function setPqOwner(WOTSPlus.WinternitzAddress calldata _pqOwner) external {
    pqOwner = _pqOwner;
  }

  /// @notice Allows direct setting of termsDigest for testing
  function setTermsDigest(bytes32 _termsDigest) external {
    termsDigest = _termsDigest;
  }
}
