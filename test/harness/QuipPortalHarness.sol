// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {QuipPortal} from '../../src/QuipPortal.sol';
import {PartyTerms, QuipTerms} from '../../src/TermsLib.sol';

/// @title QuipPortal Harness
/// @dev Exposes internal functions of QuipPortal for testing
contract QuipPortalHarness is QuipPortal {
  constructor(
    address firstAdmin,
    address quipImpl,
    uint256 maxFee,
    uint256 _creationFee
  ) QuipPortal(firstAdmin, quipImpl, maxFee, _creationFee) {}

  /// @notice Exposes _deployQuip
  function exposed_deployQuip(bytes32 lock) external returns (address) {
    return _deployQuip(lock);
  }

  /// @notice Exposes _ensureCorrectNative
  function exposed_ensureCorrectNative(uint256 amount) external payable {
    _ensureCorrectNative(amount);
  }

  /// @notice Exposes _enforceValidLock
  function exposed_enforceValidLock(bytes32 lock) external view {
    _enforceValidLock(lock);
  }

  /// @notice Exposes _enforceNonEmptyAddress
  function exposed_enforceNonEmptyAddress(address addr) external pure {
    _enforceNonEmptyAddress(addr);
  }

  /// @notice Exposes _validateQuipTerms
  function exposed_validateQuipTerms(QuipTerms calldata terms) external view {
    _validateQuipTerms(terms);
  }

  /// @notice Exposes _validatePartyTerms
  function exposed_validatePartyTerms(PartyTerms calldata terms) external view {
    _validatePartyTerms(terms);
  }

  /// @notice Exposes _onlyAdmin
  function exposed_onlyAdmin() external view {
    _onlyAdmin();
  }
}
