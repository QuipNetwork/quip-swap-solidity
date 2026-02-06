// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

interface IQuipPortal {
  /// @notice thrown when a digest is empty
  error DigestEmpty();

  /// @notice thrown when the digest of a secret has been used previously
  error SecretNotFresh();

  /// @notice thrown when the ask recipient is the zero address
  error NoAskRecipient();

  /// @notice thrown when the ask expiry is zero
  error NoAskExpiry();

  /// @notice thrown when no ask ops are provided
  error NoAskOps();

  /// @notice thrown when the asker is the zero address
  error NoAsker();

  /// @notice thrown when bidder params are non-empty during creation
  error NonEmptyBidderParams();

  /// @notice thrown when msg.value does not match the creation fee
  error InvalidFee();

  /// @notice thrown when fee exceeds MAX_FEE
  error FeeExceedsMax();

  /// @notice thrown when caller is not admin
  error NotAdmin();

  /// @notice emitted when a new quip is created
  event QuipCreated(address indexed quip);

  /// @notice emitted when fees are withdrawn
  event FeesWithdrawn(address indexed receiver, uint256 amount);

  /// @notice emitted when the creation fee is updated
  event CreationFeeUpdated(uint256 newFee);

  function isDigestSpent(bytes32 digest) external view returns (bool isSpent);
}
