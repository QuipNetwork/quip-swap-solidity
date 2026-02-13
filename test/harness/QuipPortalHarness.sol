// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {QuipPortal} from '../../src/QuipPortal.sol';
import {PartyTerms, QuipTerms} from '../../src/TermsLib.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title QuipPortal Harness
/// @dev Exposes internal functions of QuipPortal for testing
contract QuipPortalHarness is QuipPortal {
  constructor(
    address firstAdmin,
    address quipImpl,
    uint256 maxFee,
    uint256 _creationFee
  ) QuipPortal(firstAdmin, quipImpl, maxFee, _creationFee) {}

  /// @notice Exposes _ensureCorrectNative
  function exposed_ensureCorrectNative(uint256 amount) external payable {
    _ensureCorrectNative(amount);
  }

  /// @notice Exposes _enforceValidPqOwner
  function exposed_enforceValidPqOwner(
    WOTSPlus.WinternitzAddress calldata pqOwner,
    bytes32 _pqOwnerHash
  ) external view {
    _enforceValidPqOwner(pqOwner, _pqOwnerHash);
  }

  /// @notice Exposes _advancePqOwner
  function exposed_advancePqOwner(bytes32 _pqOwnerHash) external {
    _advancePqOwner(_pqOwnerHash);
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
