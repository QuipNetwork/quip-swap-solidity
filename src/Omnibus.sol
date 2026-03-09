// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType, Terms, TermsLib} from './TermsLib.sol';
import {IOmnibus, LockState} from './interfaces/IOmnibus.sol';
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
  function commit(bytes32 lock, Terms calldata party, Terms calldata counterparty) external payable {
    // validate both terms (only party.chainId must match current chain)
    TermsLib.validateTerms(party, counterparty);
    _enforceCorrectNative(TermsLib.totalNativeAmountFromTerms(party));

    bytes32 hash = TermsLib.digestTermsCanonically(party, counterparty);
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
  function execute(bytes32 secret, Terms calldata party, Terms calldata counterparty) external {
    bytes32 lock = TermsLib.generateLock(secret);

    // verify terms and state
    _enforceMatchingTerms(
      termsHash[lock], 
      TermsLib.digestTermsCanonically(party, counterparty)
    );

    // both deadlines must not have passed
    TermsLib.enforceTermFreshness(party);
    TermsLib.enforceTermFreshness(counterparty);

    LockState current = lockState[lock];
    _enforceCommittedLock(current);

    // mark as spent
    _advanceLockTo(lock, current, LockState.Spent);

    // party terms _MUST_ be on same chainId
    // counterparty terms _MAY_ be on same chainId
    bool partyOnChain = party.chainId == block.chainid;
    if (!partyOnChain) revert TermsLib.InvalidChainId();

    // party's assets to counterparty's recipient
    TermsLib.transferAssets(party.assets, address(this), counterparty.recipient);
    // return party's collateral
    TermsLib.transferAsset(party.collateral, address(this), party.signatory);

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
  function slash(bytes32 lock, Terms calldata party, Terms calldata counterparty) external {
    // slashing always happens on party
    TermsLib.enforceTermStaleness(party.deadline);
    _enforceCurrentChain(party);
    _enforceMatchingTerms(termsHash[lock], TermsLib.digestTermsCanonically(party, counterparty));

    LockState current = lockState[lock];
    _enforceCommittedLock(current);
    
    // mark as spent
    _advanceLockTo(lock, current, LockState.Spent);

    // if counterparty is also on the current chain, reclaim on their behalf since execution is no longer possible
    // NB: deadlines should be set in such a way so that the original proposer deadline is at least a block less
    // than accepting party's deadline because otherwise it is possible that accepting party may be slashed
    if (counterparty.chainId == block.chainid) {
      TermsLib.enforceTermFreshness(counterparty);
      TermsLib.transferAssets(counterparty.assets, address(this), counterparty.signatory);
      TermsLib.transferAsset(counterparty.collateral, address(this), counterparty.signatory);
      emit Reclaimed(lock, counterparty.signatory);
    }
    
    // collateral to counterparty's recipient (punishment)
    TermsLib.transferAsset(party.collateral, address(this), counterparty.recipient);
    // assets to party's signatory (return to self)
    TermsLib.transferAssets(party.assets, address(this), party.signatory);
    
    emit Slashed(lock, party.signatory, counterparty.recipient);
  }

  /// @inheritdoc IOmnibus
  function reclaim(bytes32 lock, Terms calldata party, Terms calldata counterparty) external {
    // relcaim is assumed to be called for party
    TermsLib.enforceTermFreshness(party);
    _enforceCurrentChain(party);
    _enforceMatchingTerms(termsHash[lock], TermsLib.digestTermsCanonically(party, counterparty));

    // reclaim allowed on free or committed only
    // marking as spent enforces only free or committed as previous state 
    // will revert if lock state is unused or spent
    _advanceLockTo(lock, lockState[lock], LockState.Spent);

    // reclaim counterparty if on this chain
    if (counterparty.chainId == block.chainid) {
      // return everything to counterparty's signatory
      TermsLib.enforceTermFreshness(counterparty);
      TermsLib.transferAssets(counterparty.assets, address(this), counterparty.signatory);
      TermsLib.transferAsset(counterparty.collateral, address(this), counterparty.signatory);
      emit Reclaimed(lock, counterparty.signatory);
    }

    // reclaim party if on this chain and deadline not passed
    // return everything to party's signatory
    TermsLib.transferAssets(party.assets, address(this), party.signatory);
    TermsLib.transferAsset(party.collateral, address(this), party.signatory);
      
    emit Reclaimed(lock, party.signatory);
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

  /// @notice reverts if party chainId does not match current chain
  /// @param terms the terms to check
  function _enforceCurrentChain(Terms calldata terms) internal view {
    if (terms.chainId != block.chainid) revert ChainMismatch();
  }
}
