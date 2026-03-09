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
    _enforceCorrectNative(TermsLib.totalNativeAmountV0(party));

    bytes32 hash = TermsLib.digestTermsV0Canonically(party, counterparty);
    LockState current = lockState[lock];
    LockState target;

    // invalid states (committed, spent) will revert at _advanceLockTo since is either `Free` or `Committed`
    // and no valid advancement from committed => free.committed or spent => free/committed
    if (current == LockState.Unused) {
      termsHash[lock] = hash;
      target = party.chainId == counterparty.chainId ? LockState.Free : LockState.Committed;
    }
    // no need to check sameness of chain; only way that current == LockState.Free
    // is if the terms had same chain in the previous `commit` call
    if (current == LockState.Free) {
      _enforceMatchingTerms(termsHash[lock], hash);
      target = LockState.Committed;
    }

    _advanceLockTo(lock, current, target);

    // transfer non-native assets + collateral
    TermsLib.transferNonNativeAssetsIn(party, party.signatory, address(this));

    emit Commitment(lock, party, msg.sender);
  }

  /// @inheritdoc IOmnibus
  function execute(bytes32 secret, TermsV0 calldata party, TermsV0 calldata counterparty) external {
    bytes32 lock = TermsLib.generateLock(secret);

    // verify terms and state
    _enforceMatchingTerms(
      termsHash[lock], 
      TermsLib.digestTermsV0Canonically(party, counterparty)
    );

    // both deadlines must not have passed
    TermsLib.enforceTermFreshness(party.deadline);
    TermsLib.enforceTermFreshness(counterparty.deadline);

    LockState current = lockState[lock];
    _enforceCommittedLock(current);

    // mark as spent
    _advanceLockTo(lock, current, LockState.Spent);

    // party terms _MUST_ be on same chainId
    // counterparty terms _MAY_ be on same chainId
    bool partyOnChain = party.chainId == block.chainid;
    if (!partyOnChain) revert TermsLib.InvalidChainId();

    // transfer assets for parties on this chain
    if (partyOnChain) {
      // party's assets to counterparty's recipient
      TermsLib.transferAssets(party.assets, address(this), counterparty.recipient);
      // return party's collateral
      TermsLib.transferAsset(party.collateral, address(this), party.signatory);
    }

    // if counterparty is on chainId, prevent double-spend by executing on counterparty
    // terms
    if (counterparty.chainId == block.chainid) {
      // counterparty's assets to party's recipient
      TermsLib.transferAssets(counterparty.assets, address(this), party.recipient);
      // return counterparty's collateral
      TermsLib.transferAsset(counterparty.collateral, address(this), counterparty.signatory);
    }

    emit Claim(lock, secret);
  }

  /// @inheritdoc IOmnibus
  function slash(bytes32 lock, TermsV0 calldata party, TermsV0 calldata counterparty) external {
    _enforceMatchingTerms(termsHash[lock], TermsLib.digestTermsV0Canonically(party, counterparty));
    LockState current = lockState[lock];
    _enforceCommittedLock(current);

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
    _advanceLockTo(lock, current, LockState.Spent);
  }

  /// @inheritdoc IOmnibus
  function reclaim(bytes32 lock, TermsV0 calldata party, TermsV0 calldata counterparty) external {
    _enforceMatchingTerms(termsHash[lock], TermsLib.digestTermsV0Canonically(party, counterparty));

    // reclaim allowed on free or committed
    LockState current = lockState[lock];
    if (current != LockState.Free && current != LockState.Committed) {
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
    _advanceLockTo(lock, current, LockState.Spent);
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

  /// @notice advances lock state to target with transition validation
  /// @dev valid transitions: unused->free, unused->committed, free->committed, free->spent, committed->spent
  /// @param lock the hashlock identifier
  /// @param current the current lock state (passed to avoid storage read)
  /// @param to the target lock state
  function _advanceLockTo(bytes32 lock, LockState current, LockState to) internal {
    bool advanceUnused = current == LockState.Unused && (to == LockState.Free || to == LockState.Committed);
    bool advanceFree = current == LockState.Free && (to == LockState.Committed || to == LockState.Spent);
    bool advanceCommitted = current == LockState.Committed && to == LockState.Spent;

    if (!advanceUnused && !advanceFree && !advanceCommitted) revert InvalidLockAdvancement();

    lockState[lock] = to;
  }

  /// @notice reverts if expected and actual terms hashes do not match
  /// @param expected the expected terms hash
  /// @param actual the actual terms hash
  function _enforceMatchingTerms(bytes32 expected, bytes32 actual) internal pure {
    if (expected != actual) revert TermsMismatch();
  }

  /// @notice reverts if native amount received does not match expected
  /// @param expected the expected native amount
  function _enforceCorrectNative(uint256 expected) internal view {
    if (msg.value != expected) revert IncorrectNativeAmountReceived();
  }

  /// @notice reverts if lock state is not committed
  /// @param current the current lock state
  function _enforceCommittedLock(LockState current) internal pure {
    if (current != LockState.Committed) revert InvalidLockState();
  }
}
