// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {SideTag, SideTerms} from '../protocol/ProtocolTypes.sol';

/// @title ISwapHTLC
/// @notice Custody boundary for one committed side of one Interlock swap.
/// @dev The controlling wrapper validates authorization and owns the protocol state machine. The
///      HTLC holds only the assets described by `sideTermsHash` and performs one wrapper-selected,
///      terms-fixed payout. It does not independently decide whether the trade was claimed or
///      reclaimed.
interface ISwapHTLC {
  /// @notice Thrown when a caller other than the controlling wrapper invokes a restricted action.
  error UnauthorizedController();
  /// @notice Thrown when initialization is attempted more than once.
  error AlreadyInitialized();
  /// @notice Thrown when an operation is attempted before initialization.
  error NotInitialized();
  /// @notice Thrown when supplied side terms do not match the terms bound at initialization.
  error SideTermsMismatch();
  /// @notice Thrown when funding is confirmed more than once or release precedes funding.
  error InvalidFundingState();
  /// @notice Thrown when release is attempted more than once.
  error AlreadyReleased();
  /// @notice Thrown when a release batch is asked to process no assets.
  error InvalidBatchSize();
  /// @notice Thrown when the selected payout is not one of the two terms-fixed recipients.
  error InvalidRecipient();
  /// @notice Thrown when a later release batch changes the first batch's payout recipient.
  error PayoutRecipientMismatch();
  /// @notice Thrown when initialization receives a native amount different from the signed bundle.
  error IncorrectNativeAmount();
  /// @notice Thrown when an asset required by the signed bundle is not present in full.
  error InsufficientAssetBalance();
  /// @notice Thrown when a fungible payout does not increase its recipient by the exact amount.
  error UnexpectedAmountReceived();
  /// @notice Thrown when an ERC-721 owner differs from the expected custody destination.
  error UnexpectedERC721Owner(address expected, address actual);

  /// @notice Emitted when a clone is bound to one wrapper-controlled trade side.
  event Initialized(
    address indexed controller, bytes32 indexed tradeId, bytes32 indexed lock, SideTag side, bytes32 sideTermsHash
  );
  /// @notice Emitted after the wrapper confirms that the complete signed bundle is present.
  event Funded(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side);
  /// @notice Emitted after the complete bundle is released to its fixed destination.
  event Released(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address recipient);

  /// @notice Initializes one clone and accepts this side's exact native contribution.
  /// @dev The caller becomes the permanent controller. The implementation contract must disable
  ///      its own initializer; a clone is initialized atomically by its deploying wrapper.
  function initialize(bytes32 tradeId, bytes32 lock, SideTag side, SideTerms calldata sideTerms) external payable;

  /// @notice Confirms that all assets in the signed side terms have reached this HTLC.
  /// @dev Called by the controller after it transfers non-native assets directly from the
  ///      principal. A successful commit must call this in the deployment transaction.
  function confirmFunding(SideTerms calldata sideTerms) external;

  /// @notice Releases the complete bundle once to a terms-fixed destination.
  /// @dev `recipient` must equal either `sideTerms.recipient` or
  ///      `sideTerms.reclaimRecipient`; the controlling wrapper selects between them only after
  ///      making the corresponding protocol state transition.
  function release(SideTerms calldata sideTerms, address recipient) external;

  /// @notice Releases at most `maxAssets` entries from the next unfinished bundle position.
  /// @dev Progress advances atomically with transfers and `released` becomes true only after the
  ///      complete signed asset list has been transferred.
  function releaseBatch(
    SideTerms calldata sideTerms,
    address recipient,
    uint256 maxAssets
  ) external returns (uint256 nextIndex, bool complete);

  /// @notice Wrapper that deployed this HTLC and controls its settlement.
  function controller() external view returns (address);

  /// @notice Trade identifier permanently bound to this HTLC.
  function tradeId() external view returns (bytes32);

  /// @notice Trade-bound settlement lock permanently bound to this HTLC.
  function lock() external view returns (bytes32);

  /// @notice Ordered side represented by this HTLC.
  function side() external view returns (SideTag);

  /// @notice Canonical hash of the complete signed side terms.
  function sideTermsHash() external view returns (bytes32);

  /// @notice Whether the complete signed asset bundle has been confirmed in custody.
  function funded() external view returns (bool);

  /// @notice Whether this HTLC has completed its only protocol payout.
  function released() external view returns (bool);

  /// @notice Index of the next signed asset entry awaiting payout.
  function nextAssetIndex() external view returns (uint256);

  /// @notice Terms-fixed recipient selected by the first successful release batch.
  function payoutRecipient() external view returns (address);
}
