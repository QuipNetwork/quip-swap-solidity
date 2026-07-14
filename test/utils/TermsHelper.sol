// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, Terms} from '../../src/TermsLib.sol';

/// @title Terms Helper
/// @dev Utility functions for building Terms structs in tests
library TermsHelper {
  /// @notice creates a Terms struct with an explicit commit sender
  /// @param chainId the chain where these terms' assets are held
  /// @param sender the address allowed to submit and fund this side's commit
  /// @param reclaimRecipient address that receives committed assets on reclaim
  /// @param recipient address that receives the counterparty's assets on claim
  /// @param commitmentDeadline timestamp after which commitment is forbidden
  /// @param claimDeadline timestamp after which claiming is forbidden
  /// @param reclaimRelease timestamp after which reclaim is permitted
  /// @param assets the assets array
  /// @return terms the constructed Terms struct
  function makeTerms(
    uint256 chainId,
    address sender,
    address reclaimRecipient,
    address recipient,
    uint256 commitmentDeadline,
    uint256 claimDeadline,
    uint256 reclaimRelease,
    Asset[] memory assets
  ) internal pure returns (Terms memory terms) {
    terms = Terms({
      chainId: chainId,
      sender: sender,
      reclaimRecipient: reclaimRecipient,
      recipient: recipient,
      commitmentDeadline: commitmentDeadline,
      claimDeadline: claimDeadline,
      reclaimRelease: reclaimRelease,
      assets: assets
    });
  }

  /// @notice creates a Terms struct from explicit lifecycle deadlines
  /// @param chainId the chain where these terms' assets are held
  /// @dev convenience overload for tests where sender and reclaimRecipient are the same actor
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
    return makeTerms(
      chainId, reclaimRecipient, reclaimRecipient, recipient, commitmentDeadline, claimDeadline, reclaimRelease, assets
    );
  }
}
