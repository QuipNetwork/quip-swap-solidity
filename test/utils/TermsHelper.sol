// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, Terms} from '../../src/TermsLib.sol';

/// @title Terms Helper
/// @dev Utility functions for building Terms structs in tests
library TermsHelper {
  /// @notice creates Terms struct
  /// @param chainId the chain where these terms are valid
  /// @param signatory the party's address
  /// @param recipient the recipient's address
  /// @param deadline the deadline timestamp
  /// @param assets the assets array
  /// @return terms the constructed Terms struct
  function makeTerms(
    uint256 chainId,
    address signatory,
    address recipient,
    uint64 deadline,
    Asset[] memory assets
  ) internal pure returns (Terms memory terms) {
    terms = Terms({
      chainId: chainId,
      signatory: signatory,
      recipient: recipient,
      deadline: deadline,
      assets: assets
    });
  }
}
