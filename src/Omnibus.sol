// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType, LockState, TermsV0, TermsLib} from './TermsLib.sol';
import {IOmnibus} from './interfaces/IOmnibus.sol';
import {IERC1155Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155Receiver.sol';
import {IERC721Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721Receiver.sol';

/// @title Omnibus
/// @notice Singleton contract for cross-chain swaps using hashlock and collateral
contract Omnibus is IOmnibus, IERC721Receiver, IERC1155Receiver {
  /// @notice the version of this omnibus implementation
  uint256 public constant VERSION = 0;

  /// @inheritdoc IOmnibus
  mapping(bytes32 lock => LockState) public lockState;

  /// @inheritdoc IOmnibus
  mapping(bytes32 lock => bytes32) public termsHash;

  /// @notice allows this contract to receive native currency
  receive() external payable {}

  /// @inheritdoc IOmnibus
  function commit(bytes32 lock, TermsV0 calldata party, TermsV0 calldata counterparty) external payable {
    // validate both terms (only party.chainId must match current chain)
    TermsLib.validateTermsV0(party, counterparty);

    // generate canonical hash
    bytes32 hash = TermsLib.digestTermsV0Canonically(party, counterparty);

    // branch on lock state
    if (lockState[lock] == LockState.Unused) {
      termsHash[lock] = hash;
    } else if (lockState[lock] == LockState.Free) {
      if (termsHash[lock] != hash) revert InvalidTerms();
    } else {
      revert LockAlreadySpent();
    }

    // advance lock state based on same-chain vs cross-chain
    _advanceLock(lock, party.chainId == counterparty.chainId);

    // verify native amount
    if (msg.value != TermsLib.totalNativeAmountV0(party)) revert InsufficientCommitment();

    // transfer non-native assets + collateral
    TermsLib.transferNonNativeAssetsIn(party, msg.sender, address(this));

    emit Commitment(lock, party, msg.sender);
  }

  /// @inheritdoc IOmnibus
  function execute(bytes32 secret, TermsV0 calldata party, TermsV0 calldata counterparty) external {
    bytes32 lock = TermsLib.generateLock(secret);

    // verify terms and state
    if (termsHash[lock] != TermsLib.digestTermsV0Canonically(party, counterparty)) revert InvalidTerms();
    if (lockState[lock] != LockState.Committed) revert InvalidLockState();

    // both deadlines must not have passed
    TermsLib.enforceTermFreshness(party.deadline);
    TermsLib.enforceTermFreshness(counterparty.deadline);

    // at least one party must match this chain
    bool partyOnChain = party.chainId == block.chainid;
    bool counterpartyOnChain = counterparty.chainId == block.chainid;
    if (!partyOnChain && !counterpartyOnChain) revert TermsLib.InvalidChainId();

    // transfer assets for parties on this chain
    if (partyOnChain) {
      // party's assets to counterparty's recipient
      TermsLib.transferAssets(party.assets, address(this), counterparty.recipient);
      // return party's collateral
      TermsLib.transferAsset(party.collateral, address(this), party.signatory);
    }

    if (counterpartyOnChain) {
      // counterparty's assets to party's recipient
      TermsLib.transferAssets(counterparty.assets, address(this), party.recipient);
      // return counterparty's collateral
      TermsLib.transferAsset(counterparty.collateral, address(this), counterparty.signatory);
    }

    // mark as spent
    _advanceLock(lock, LockState.Spent);
    emit Claim(lock, secret);
  }

  /// @inheritdoc IOmnibus
  function slash(bytes32 lock, TermsV0 calldata party, TermsV0 calldata counterparty) external {
    // verify terms and state
    if (termsHash[lock] != TermsLib.digestTermsV0Canonically(party, counterparty)) revert InvalidTerms();
    if (lockState[lock] != LockState.Committed) revert InvalidLockState();

    bool slashedAny = false;

    // slash party if on this chain and deadline passed
    if (party.chainId == block.chainid && block.timestamp >= party.deadline) {
      // collateral to counterparty's recipient (punishment)
      TermsLib.transferAsset(party.collateral, address(this), counterparty.recipient);
      // assets to party's signatory (return to self)
      TermsLib.transferAssets(party.assets, address(this), party.signatory);
      emit Slashed(lock, party.signatory, counterparty.recipient);
      slashedAny = true;
    }

    // slash counterparty if on this chain and deadline passed
    if (counterparty.chainId == block.chainid && block.timestamp >= counterparty.deadline) {
      // collateral to party's recipient (punishment)
      TermsLib.transferAsset(counterparty.collateral, address(this), party.recipient);
      // assets to counterparty's signatory (return to self)
      TermsLib.transferAssets(counterparty.assets, address(this), counterparty.signatory);
      emit Slashed(lock, counterparty.signatory, party.recipient);
      slashedAny = true;
    }

    if (!slashedAny) revert InvalidSlash();

    // mark as spent
    _advanceLock(lock, LockState.Spent);
  }

  /// @inheritdoc IOmnibus
  function reclaim(bytes32 lock, TermsV0 calldata party, TermsV0 calldata counterparty) external {
    // verify terms
    if (termsHash[lock] != TermsLib.digestTermsV0Canonically(party, counterparty)) revert InvalidTerms();

    // reclaim allowed on free or committed
    if (lockState[lock] != LockState.Free && lockState[lock] != LockState.Committed) {
      revert InvalidLockState();
    }

    bool reclaimedAny = false;

    // reclaim party if on this chain and deadline not passed
    if (party.chainId == block.chainid && block.timestamp < party.deadline) {
      // return everything to party's signatory
      TermsLib.transferAssets(party.assets, address(this), party.signatory);
      TermsLib.transferAsset(party.collateral, address(this), party.signatory);
      emit Reclaimed(lock, party.signatory);
      reclaimedAny = true;
    }

    // reclaim counterparty if on this chain and deadline not passed
    if (counterparty.chainId == block.chainid && block.timestamp < counterparty.deadline) {
      // return everything to counterparty's signatory
      TermsLib.transferAssets(counterparty.assets, address(this), counterparty.signatory);
      TermsLib.transferAsset(counterparty.collateral, address(this), counterparty.signatory);
      emit Reclaimed(lock, counterparty.signatory);
      reclaimedAny = true;
    }

    if (!reclaimedAny) revert InvalidReclaim();

    // mark as spent
    _advanceLock(lock, LockState.Spent);
  }

  /// @notice ERC721 receiver callback to accept NFT transfers
  function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
    return IERC721Receiver.onERC721Received.selector;
  }

  /// @notice ERC1155 receiver callback to accept single token transfers
  function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
    return IERC1155Receiver.onERC1155Received.selector;
  }

  /// @notice ERC1155 receiver callback to accept batch token transfers
  function onERC1155BatchReceived(
    address,
    address,
    uint256[] calldata,
    uint256[] calldata,
    bytes calldata
  ) external pure returns (bytes4) {
    return IERC1155Receiver.onERC1155BatchReceived.selector;
  }

  /// @notice ERC165 interface support
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return interfaceId == type(IERC721Receiver).interfaceId || interfaceId == type(IERC1155Receiver).interfaceId;
  }

  /// @notice advances lock state to target and clears terms hash
  /// @param lock the hashlock identifier
  /// @param target the target lock state
  function _advanceLock(bytes32 lock, LockState target) internal {
    lockState[lock] = target;
    if (target == LockState.Spent) {
      delete termsHash[lock];
    }
  }

  /// @notice advances lock state for commit based on same-chain vs cross-chain
  /// @param lock the hashlock identifier
  /// @param sameChain whether party and counterparty are on the same chain
  function _advanceLock(bytes32 lock, bool sameChain) internal {
    if (sameChain) {
      // same-chain: unused -> free -> committed
      lockState[lock] = lockState[lock] == LockState.Unused ? LockState.Free : LockState.Committed;
    } else {
      // cross-chain: unused -> committed directly
      lockState[lock] = LockState.Committed;
    }
  }
}
