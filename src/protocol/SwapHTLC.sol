// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ISwapHTLC} from '../interfaces/ISwapHTLC.sol';
import {ProtocolHashing} from './ProtocolHashing.sol';
import {Asset, AssetType, SideTag, SideTerms} from './ProtocolTypes.sol';
import {IERC1155} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155.sol';
import {ERC1155Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/utils/ERC1155Holder.sol';
import {IERC721} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721.sol';
import {ERC721Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/utils/ERC721Holder.sol';
import {ReentrancyGuard} from '@openzeppelin-contracts-5.6.0-rc.1/utils/ReentrancyGuard.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

/// @title SwapHTLC
/// @notice Holds one committed side's exact asset bundle until its wrapper selects a signed payout.
/// @dev Instances are deterministic minimal clones. The implementation disables its initializer in
///      the constructor, while each clone begins with empty storage and is initialized atomically by
///      its deploying wrapper. This contract enforces custody and payout; protocol timing, secrets,
///      authorization, and the claim-versus-reclaim decision remain exclusively in the wrapper.
contract SwapHTLC is ISwapHTLC, ERC721Holder, ERC1155Holder, ReentrancyGuard {
  address public override controller;
  bytes32 public override tradeId;
  bytes32 public override lock;
  bytes32 public override sideTermsHash;
  SideTag public override side;
  bool public override funded;
  bool public override released;

  bool private initialized;

  /// @dev Locks the implementation contract while leaving clone storage uninitialized.
  constructor() {
    initialized = true;
  }

  modifier onlyController() {
    if (!initialized) revert NotInitialized();
    if (msg.sender != controller) revert UnauthorizedController();
    _;
  }

  /// @inheritdoc ISwapHTLC
  function initialize(
    bytes32 tradeId_,
    bytes32 lock_,
    SideTag side_,
    SideTerms calldata sideTerms_
  ) external payable override {
    if (initialized) revert AlreadyInitialized();
    initialized = true;

    uint256 expectedNative;
    for (uint256 i; i < sideTerms_.assets.length; ++i) {
      if (sideTerms_.assets[i].assetType == AssetType.Native) expectedNative += sideTerms_.assets[i].amount;
    }
    if (msg.value != expectedNative) revert IncorrectNativeAmount();

    controller = msg.sender;
    tradeId = tradeId_;
    lock = lock_;
    side = side_;
    sideTermsHash = ProtocolHashing.sideTermsHash(sideTerms_);

    emit Initialized(msg.sender, tradeId_, lock_, side_, sideTermsHash);
  }

  /// @inheritdoc ISwapHTLC
  function confirmFunding(SideTerms calldata sideTerms_) external override onlyController {
    if (funded || released) revert InvalidFundingState();
    _requireBoundTerms(sideTerms_);
    for (uint256 i; i < sideTerms_.assets.length; ++i) {
      if (!_hasAsset(sideTerms_.assets[i])) revert InsufficientAssetBalance();
    }
    funded = true;
    emit Funded(tradeId, lock, side);
  }

  /// @inheritdoc ISwapHTLC
  function release(SideTerms calldata sideTerms_, address recipient) external override onlyController nonReentrant {
    if (!funded) revert InvalidFundingState();
    if (released) revert AlreadyReleased();
    _requireBoundTerms(sideTerms_);
    if (recipient != sideTerms_.recipient && recipient != sideTerms_.reclaimRecipient) revert InvalidRecipient();
    if (recipient == address(this)) revert InvalidRecipient();

    // Record the one-time effect before interacting with token contracts or the recipient.
    released = true;
    for (uint256 i; i < sideTerms_.assets.length; ++i) {
      _transfer(sideTerms_.assets[i], recipient);
    }
    emit Released(tradeId, lock, side, recipient);
  }

  function _requireBoundTerms(SideTerms calldata sideTerms_) private view {
    if (ProtocolHashing.sideTermsHash(sideTerms_) != sideTermsHash) revert SideTermsMismatch();
  }

  function _hasAsset(Asset calldata asset) private view returns (bool) {
    if (asset.assetType == AssetType.Native) return address(this).balance >= asset.amount;
    if (asset.assetType == AssetType.ERC20) {
      return SafeTransferLib.balanceOf(asset.target, address(this)) >= asset.amount;
    }
    if (asset.assetType == AssetType.ERC1155) {
      return IERC1155(asset.target).balanceOf(address(this), asset.id) >= asset.amount;
    }
    try IERC721(asset.target).ownerOf(asset.id) returns (address owner) {
      return owner == address(this);
    } catch {
      return false;
    }
  }

  function _transfer(Asset calldata asset, address recipient) private {
    if (asset.assetType == AssetType.Native) {
      SafeTransferLib.safeTransferETH(recipient, asset.amount);
    } else if (asset.assetType == AssetType.ERC20) {
      uint256 beforeBalance = SafeTransferLib.balanceOf(asset.target, recipient);
      SafeTransferLib.safeTransfer(asset.target, recipient, asset.amount);
      uint256 afterBalance = SafeTransferLib.balanceOf(asset.target, recipient);
      if (afterBalance < beforeBalance || afterBalance - beforeBalance != asset.amount) {
        revert UnexpectedAmountReceived();
      }
    } else if (asset.assetType == AssetType.ERC721) {
      IERC721(asset.target).safeTransferFrom(address(this), recipient, asset.id);
      _requireERC721Owner(asset, recipient);
    } else {
      uint256 beforeBalance = IERC1155(asset.target).balanceOf(recipient, asset.id);
      IERC1155(asset.target).safeTransferFrom(address(this), recipient, asset.id, asset.amount, '');
      uint256 afterBalance = IERC1155(asset.target).balanceOf(recipient, asset.id);
      if (afterBalance < beforeBalance || afterBalance - beforeBalance != asset.amount) {
        revert UnexpectedAmountReceived();
      }
    }
  }

  function _requireERC721Owner(Asset calldata asset, address expected) private view {
    try IERC721(asset.target).ownerOf(asset.id) returns (address actual) {
      if (actual != expected) revert UnexpectedERC721Owner(expected, actual);
    } catch {
      revert UnexpectedERC721Owner(expected, address(0));
    }
  }
}
