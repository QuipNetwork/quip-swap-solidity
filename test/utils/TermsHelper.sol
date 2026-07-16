// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, Terms} from '../../src/TermsLib.sol';

/// @title Terms Helper
/// @dev Utility functions for building Terms structs in tests
library TermsHelper {
  /// @notice creates a non-optimistic Terms struct from explicit lifecycle deadlines
  /// @param chainId the chain where these terms' assets are held
  /// @param reclaimRecipient address that receives committed assets on reclaim
  /// @param recipient address that receives the counterparty's assets on claim
  /// @param commitmentDeadline timestamp after which commitment is forbidden
  /// @param claimDeadline timestamp after which claiming is forbidden
  /// @param reclaimRelease timestamp after which reclaim is permitted
  /// @param assets the assets array
  /// @return terms the constructed Terms struct
  function makeTerms(
    uint256 chainId,
    address reclaimRecipient,
    address recipient,
    uint256 commitmentDeadline,
    uint256 claimDeadline,
    uint256 reclaimRelease,
    Asset[] memory assets
  ) internal pure returns (Terms memory terms) {
    terms = Terms({
      chainId: chainId,
      reclaimRecipient: reclaimRecipient,
      recipient: recipient,
      commitmentDeadline: commitmentDeadline,
      claimDeadline: claimDeadline,
      reclaimRelease: reclaimRelease,
      optimistic: false,
      assets: assets
    });
  }

  /// @notice creates an optimistic Terms struct (commit/claim window lower bounds waived)
  /// from explicit lifecycle deadlines
  /// @param chainId the chain where these terms' assets are held
  /// @param reclaimRecipient address that receives committed assets on reclaim
  /// @param recipient address that receives the counterparty's assets on claim
  /// @param commitmentDeadline timestamp after which commitment is forbidden
  /// @param claimDeadline timestamp after which claiming is forbidden
  /// @param reclaimRelease timestamp after which reclaim is permitted
  /// @param assets the assets array
  /// @return terms the constructed Terms struct
  function makeOptimisticTerms(
    uint256 chainId,
    address reclaimRecipient,
    address recipient,
    uint256 commitmentDeadline,
    uint256 claimDeadline,
    uint256 reclaimRelease,
    Asset[] memory assets
  ) internal pure returns (Terms memory terms) {
    terms = makeTerms(chainId, reclaimRecipient, recipient, commitmentDeadline, claimDeadline, reclaimRelease, assets);
    terms.optimistic = true;
  }

  /// @notice returns `terms` with the optimistic flag set (mutates the memory struct)
  /// @param terms the terms to mark optimistic
  /// @return the same terms with optimistic = true
  function withOptimistic(Terms memory terms) internal pure returns (Terms memory) {
    terms.optimistic = true;
    return terms;
  }
}
