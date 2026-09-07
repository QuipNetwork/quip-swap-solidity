// SPDX-License-Identifier: UNLICENSE
// Pin the compiler version used for these encodings and contract semantics.
pragma solidity 0.8.33;

// Import asset-standard balance and exact-transfer adapters.
import {AssetTransfers} from '../assets/AssetHandling.sol';
// Import custody initialization, funding, binding, and release interface.
import {ISwapHTLC} from '../interfaces/ISwapHTLC.sol';
// Import canonical term validation and domain-separated identifiers.
import {ProtocolHashing} from './ProtocolHashing.sol';
// Import canonical token identity and quantity representation; Supported native, fungible, and NFT transfer-standard
// tags; Canonical party and counterparty side tags; One side's signed assets, identities, destinations, and deadlines.
import {Asset, AssetType, SideTag, SideTerms} from './ProtocolTypes.sol';
// Import standard ERC-1155 receiver callbacks for safe custody transfers.
import {ERC1155Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/utils/ERC1155Holder.sol';
// Import standard ERC-721 receiver callback for safe custody transfers.
import {ERC721Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/utils/ERC721Holder.sol';
// Import protection against nested guarded custody entry points.
import {ReentrancyGuard} from '@openzeppelin-contracts-5.6.0-rc.1/utils/ReentrancyGuard.sol';

/// @title SwapHTLC
/// @notice Holds one committed side's exact asset bundle until its wrapper selects a signed payout.
/// @dev Instances are deterministic minimal clones. The implementation disables its initializer in
///      the constructor, while each clone begins with empty storage and is initialized atomically by
///      its deploying wrapper. This contract enforces custody and payout; protocol timing, secrets,
///      authorization, and the claim-versus-reclaim decision remain exclusively in the wrapper.
contract SwapHTLC is ISwapHTLC, ERC721Holder, ERC1155Holder, ReentrancyGuard {
  // Initializing wrapper and sole authority over custody release.
  address public override controller;
  // Hash of the complete ordered terms.
  bytes32 public override tradeId;
  // Trade-bound settlement hash lock.
  bytes32 public override lock;
  // Hash binding this custody instance to every signed side field.
  bytes32 public override sideTermsHash;
  // Ordered side whose assets or state this operation addresses.
  SideTag public override side;
  // True once the controller has confirmed all signed asset balances.
  bool public override funded;
  // True once every asset in the bundle has been released.
  bool public override released;
  // First asset not yet released from the signed bundle.
  uint256 public override nextAssetIndex;
  // Destination fixed by the first successful release batch.
  address public override payoutRecipient;

  // One-time initializer guard; set in the implementation constructor.
  bool private initialized;

  /// @dev Locks the implementation contract while leaving clone storage uninitialized.
  constructor() {
    // Block later initializer calls on this storage instance.
    initialized = true;
  }

  // Restrict custody operations to the initializing wrapper.
  modifier onlyController() {
    // The clone must be initialized before controller operations.
    if (!initialized) revert NotInitialized();
    // Only the initializing wrapper may control this custody instance.
    if (msg.sender != controller) revert UnauthorizedController();

    // Continue the protected function only after initialization and caller checks pass.
    _;
  }

  /// @inheritdoc ISwapHTLC
  function initialize(
    // Hash of the complete ordered terms.
    bytes32 tradeId_,
    // Trade-bound settlement hash lock.
    bytes32 lock_,
    // Ordered side whose assets or state this operation addresses.
    SideTag side_,
    // Complete side terms used to verify custody binding.
    SideTerms calldata sideTerms_
    // Receive this clone's native escrow while binding its one-time initialization.
  ) external payable override {
    // A custody instance may be initialized only once.
    if (initialized) revert AlreadyInitialized();
    // Block later initializer calls on this storage instance.
    initialized = true;

    // Accumulate the native portion of the signed bundle.
    uint256 expectedNative;

    // Inspect each asset in the complete signed bundle.
    for (uint256 i; i < sideTerms_.assets.length; ++i) {
      // Include native currency amounts while leaving token quantities out of msg.value accounting.
      if (sideTerms_.assets[i].assetType == AssetType.Native) expectedNative += sideTerms_.assets[i].amount;
    }
    // The attached native value differs from the amount required by this operation.
    if (msg.value != expectedNative) revert IncorrectNativeAmount();

    // Reject self-payout destinations that would mark release complete without moving custody.
    if (sideTerms_.recipient == address(this) || sideTerms_.reclaimRecipient == address(this)) {
      // The destination is not an admissible signed payout address.
      revert InvalidRecipient();
    }

    // Bind the initializing wrapper as the only address allowed to control custody.
    controller = msg.sender;
    // Store the complete-trade identifier supplied by the deploying wrapper.
    tradeId = tradeId_;
    // Store the settlement lock belonging to this custody instance.
    lock = lock_;
    // Store which ordered leg this clone holds.
    side = side_;
    // Bind every signed side field without duplicating the dynamic asset array in storage.
    sideTermsHash = ProtocolHashing.sideTermsHash(sideTerms_);

    // Expose the controller and exact trade-side binding of this initialized custody instance.
    emit Initialized(msg.sender, tradeId_, lock_, side_, sideTermsHash);
  }

  /// @inheritdoc ISwapHTLC
  function confirmFunding(SideTerms calldata sideTerms_) external override onlyController {
    // Custody is not in the funding state required by this operation.
    if (funded || released) revert InvalidFundingState();
    // Require exactly the side terms bound during initialization.
    _requireBoundTerms(sideTerms_);

    // Inspect each asset in the complete signed bundle.
    for (uint256 i; i < sideTerms_.assets.length; ++i) {
      // The custody balance does not cover a signed asset quantity.
      if (!_hasAsset(sideTerms_.assets[i])) revert InsufficientAssetBalance();
    }

    // Mark custody ready only after all signed balances have been checked.
    funded = true;

    // Report that this custody instance has confirmed its complete signed asset bundle.
    emit Funded(tradeId, lock, side);
  }

  /// @inheritdoc ISwapHTLC
  function release(SideTerms calldata sideTerms_, address recipient) external override onlyController nonReentrant {
    // Use the batch engine with a cap sufficient to release the entire remaining bundle.
    _releaseBatch(sideTerms_, recipient, sideTerms_.assets.length);
  }

  /// @inheritdoc ISwapHTLC
  function releaseBatch(
    // Complete side terms used to verify custody binding.
    SideTerms calldata sideTerms_,
    // Fixed signed payout destination selected by the outcome.
    address recipient,
    // Maximum number of assets this call may release.
    uint256 maxAssets
    // Only the controller may execute a guarded batch and receive its progress result.
  ) external override onlyController nonReentrant returns (uint256 nextIndex, bool complete) {
    // Use the batch engine with the caller's asset-count cap.
    _releaseBatch(sideTerms_, recipient, maxAssets);

    // Return the persisted cursor and final custody-release status.
    return (nextAssetIndex, released);
  }

  // Release a bounded asset range while fixing the destination across successful batches.
  function _releaseBatch(SideTerms calldata sideTerms_, address recipient, uint256 maxAssets) private {
    // Custody is not in the funding state required by this operation.
    if (!funded) revert InvalidFundingState();
    // All assets have already been released.
    if (released) revert AlreadyReleased();
    // A settlement batch must allow at least one asset.
    if (maxAssets == 0) revert InvalidBatchSize();
    // Require exactly the side terms bound during initialization.
    _requireBoundTerms(sideTerms_);

    // The destination is not an admissible signed payout address.
    if (recipient != sideTerms_.recipient && recipient != sideTerms_.reclaimRecipient) revert InvalidRecipient();
    // The destination is not an admissible signed payout address.
    if (recipient == address(this)) revert InvalidRecipient();

    // Resume from the first asset not released by an earlier successful batch.
    uint256 start = nextAssetIndex;
    // Bind the destination on the first batch so later batches cannot switch outcomes.
    if (start == 0) payoutRecipient = recipient;
    // Later batches cannot change the destination fixed by the first batch.
    else if (recipient != payoutRecipient) revert PayoutRecipientMismatch();

    // Count assets still held for this side.
    uint256 remaining = sideTerms_.assets.length - start;
    // Cap work at the smaller of the requested batch and remaining assets.
    uint256 count = maxAssets < remaining ? maxAssets : remaining;
    // Compute the exclusive end of this batch.
    uint256 end = start + count;

    // Advance progress before external calls; any failed transfer reverts the complete batch.
    nextAssetIndex = end;
    // Set released only when the cursor reaches the end of the signed bundle.
    released = end == sideTerms_.assets.length;

    // Visit only assets assigned to this batch.
    for (uint256 i = start; i < end; ++i) {
      // Perform an exact transfer to the fixed destination; failure rolls back this batch.
      _transfer(sideTerms_.assets[i], recipient);
    }

    // Emit the custody completion event only after the final batch succeeds.
    if (released) emit Released(tradeId, lock, side, recipient);
  }

  // Reject any side fields that differ from initialization.
  function _requireBoundTerms(SideTerms calldata sideTerms_) private view {
    // The supplied side differs from the hash stored during initialization.
    if (ProtocolHashing.sideTermsHash(sideTerms_) != sideTermsHash) revert SideTermsMismatch();
  }

  // Check whether custody covers the signed quantity of one asset.
  function _hasAsset(Asset calldata asset) private view returns (bool) {
    // Treat ERC-721 ownership as one unit and use the signed quantity for other standards.
    uint256 expected = asset.assetType == AssetType.ERC721 ? 1 : asset.amount;
    // Check custody against the expected quantity using the asset-standard adapter.
    return AssetTransfers.balanceOf(asset, address(this)) >= expected;
  }

  // Use the asset-standard adapter to transfer exactly the signed quantity.
  function _transfer(Asset calldata asset, address recipient) private {
    // Perform an exact transfer to the fixed destination; failure rolls back this batch.
    AssetTransfers.transferExact(asset, address(this), recipient);
  }
}
