// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

interface IQuipPortal {
  /// @notice thrown when a digest is empty
  error DigestEmpty();

  /// @notice thrown when the digest of a secret has been used previously
  error SecretNotFresh();

  /// @notice thrown when the party recipient is the zero address
  error NoPartyRecipient();

  /// @notice thrown when the party expiry is zero
  error NoPartyExpiry();

  /// @notice thrown when no party assets are provided
  error NoPartyAssets();

  /// @notice thrown when the party is the zero address
  error NoParty();

  /// @notice thrown when the counterparty is the zero address
  error NoCounterparty();

  /// @notice thrown when the counterparty recipient is the zero address
  error NoCounterpartyRecipient();

  /// @notice thrown when the counterparty expiry is zero
  error NoCounterpartyExpiry();

  /// @notice thrown when no counterparty assets are provided
  error NoCounterpartyAssets();

  /// @notice thrown when msg.value does not match expected native amount
  error IncorrectNativeAmount();

  /// @notice thrown when fee exceeds MAX_FEE
  error FeeExceedsMax();

  /// @notice thrown when withdrawal amount exceeds accumulated fees
  error InsufficientFees();

  /// @notice thrown when caller is not admin
  error NotAdmin();

  /// @notice emitted when a new quip is created
  event QuipCreated(address indexed quip);

  /// @notice emitted when fees are withdrawn
  event FeesWithdrawn(address indexed receiver, uint256 amount);

  /// @notice emitted when the creation fee is updated
  event CreationFeeUpdated(uint256 newFee);

  /// @notice returns whether a secret digest has already been used
  /// @param digest the secret digest to check
  /// @return isSpent true if the digest has been used
  function isDigestSpent(bytes32 digest) external view returns (bool isSpent);
}
