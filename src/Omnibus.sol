// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from './TermsLib.sol';
import {IOmnibus, LockState} from './interfaces/IOmnibus.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';
import {IERC1155Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155Receiver.sol';
import {IERC721Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721Receiver.sol';
import {Ownable2Step, Ownable} from '@openzeppelin-contracts-5.6.0-rc.1/access/Ownable2Step.sol';

/// @title Omnibus
/// @notice Singleton contract for cross-chain swaps using hashlock
contract Omnibus is IOmnibus, IERC721Receiver, IERC1155Receiver, Ownable2Step {
  using TermsLib for Terms;

  /// @notice the version of this omnibus implementation
  uint256 public constant VERSION = 0;

  /// @inheritdoc IOmnibus
  uint256 public constant MAX_FEE = 0.01 ether;

  /// @inheritdoc IOmnibus
  uint256 public commitmentFee;

  /// @inheritdoc IOmnibus
  uint256 public accruedFees;

  /// @inheritdoc IOmnibus
  mapping(bytes32 lock => LockState state) public lockState;

  /// @inheritdoc IOmnibus
  mapping(bytes32 lock => bytes32 canonicalDigest) public termsHash;

  /// @inheritdoc IOmnibus
  mapping(bytes32 lock => mapping(bytes32 termsDigest => bool isPosted)) public posted;

  /// @notice initializes the contract with an owner
  /// @param initialOwner the address that will own the contract
  constructor(address initialOwner) Ownable(initialOwner) {}

  /// @notice allows this contract to receive native currency
  receive() external payable {}

  /// @inheritdoc IOmnibus
  function commit(bytes32 lock, Terms calldata party, Terms calldata counterparty) external payable {
    // validate both terms (only party.chainId must match current chain)
    party.enforceChainId(block.chainid);
    // assets are pulled from party.signatory, so only the signatory may commit its side
    _enforceSignatoryCaller(party);
    party.validateTerms();
    counterparty.validateTerms();
    _enforceCorrectNative(party.totalNative() + commitmentFee);

    bytes32 canonicalDigest = TermsLib.digestTermsCanonically(party, counterparty);
    bytes32 partyDigest = party.digestTerms();
    LockState current = lockState[lock];
    LockState target;

    // invalid states (committed, spent) will revert at _advanceLockTo since is either `Free` or `Committed`
    // and no valid advancement from committed => free.committed or spent => free/committed
    if (current == LockState.Unused) {
      termsHash[lock] = canonicalDigest;
      target = party.chainId == counterparty.chainId ? LockState.Free : LockState.Committed;
    }
    // no need to check sameness of chain; only way that current == LockState.Free
    // is if the terms had same chain in the previous `commit` call
    if (current == LockState.Free) {
      _enforceSameTerms(termsHash[lock], canonicalDigest);
      // second same-chain commit must post the other side, not re-post the same one
      if (posted[lock][partyDigest]) revert TermsAlreadyPosted();
      target = LockState.Committed;
    }

    _advanceLockTo(lock, current, target);

    // accrue the fee; the rest of msg.value is escrowed native owed back to depositors
    accruedFees += commitmentFee;

    // record the side this commit posts
    posted[lock][partyDigest] = true;

    // transfer non-native assets
    party.transferAssetsNoNative(party.signatory, address(this));

    emit Commitment(lock, party, msg.sender);
  }

  /// @inheritdoc IOmnibus
  function execute(bytes32 secret, Terms calldata party, Terms calldata counterparty) external {
    bytes32 lock = _generateLock(secret);

    // verify terms and state
    _enforceSameTerms(
      termsHash[lock],
      TermsLib.digestTermsCanonically(party, counterparty)
    );

    // party terms _MUST_ be on same chainId
    // counterparty terms _MAY_ be on same chainId
    party.enforceChainId(block.chainid);

    // both deadlines must not have passed
    party.enforceTermFreshness();
    counterparty.enforceTermFreshness();

    LockState current = lockState[lock];
    _enforceCommittedLock(current);

    // mark as spent
    _advanceLockTo(lock, current, LockState.Spent);

    // party's side must have been posted for this lock
    _enforcePosted(lock, party.digestTerms());

    // party's assets to counterparty's recipient
    party.transferAssets(address(this), counterparty.recipient);

    // if counterparty is on chainId, prevent double-spend by executing on counterparty
    // terms
    if (counterparty.chainId == block.chainid) {
      // counterparty's side must have been posted for this lock
      _enforcePosted(lock, counterparty.digestTerms());
      // counterparty's assets to party's recipient
      counterparty.transferAssets(address(this), party.recipient);
    }

    emit Claim(lock, secret);
  }

  /// @inheritdoc IOmnibus
  function reclaim(bytes32 lock, Terms calldata party, Terms calldata counterparty) external {
    // reclaim is assumed to be called for party
    party.enforceTermStaleness();
    party.enforceChainId(block.chainid);
    _enforceSameTerms(termsHash[lock], TermsLib.digestTermsCanonically(party, counterparty));
    // party's side must have been posted for this lock; checked after the terms are
    // proven genuine so the more specific reverts surface first
    _enforcePosted(lock, party.digestTerms());

    LockState current = lockState[lock];
    // reclaim allowed on free or committed only
    // marking as spent enforces only free or committed as previous state 
    // will revert if lock state is unused or spent
    _advanceLockTo(lock, current, LockState.Spent);

    // reclaim counterparty if on this chain and the current state is committed
    // meaning counterparty has committed their assets
    if (counterparty.chainId == block.chainid && current == LockState.Committed) {
      // return everything to counterparty's signatory
      counterparty.enforceTermStaleness();
      // counterparty's side must have been posted for this lock
      _enforcePosted(lock, counterparty.digestTerms());
      counterparty.transferAssets(address(this), counterparty.signatory);
      emit Reclaimed(lock, counterparty.signatory);
    }

    // return everything to party's signatory
    party.transferAssets(address(this), party.signatory);
      
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

  /// @inheritdoc IOmnibus
  function setCommitmentFee(uint256 newFee) external onlyOwner {
    if (newFee > MAX_FEE) revert FeeExceedsMax();
    uint256 oldFee = commitmentFee;
    commitmentFee = newFee;
    emit FeeUpdated(oldFee, newFee);
  }

  /// @inheritdoc IOmnibus
  function withdrawFees(address to) external onlyOwner {
    // only accrued fees are withdrawable; escrowed native stays owed to depositors
    uint256 amount = accruedFees;
    delete accruedFees;
    SafeTransferLib.safeTransferETH(to, amount);
    emit FeesWithdrawn(to, amount);
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
  function _enforceSameTerms(bytes32 expected, bytes32 actual) internal pure {
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

  /// @notice reverts if a side was not posted for the lock
  /// @param lock the hashlock identifier
  /// @param termsDigest the side's terms digest
  function _enforcePosted(bytes32 lock, bytes32 termsDigest) internal view {
    if (!posted[lock][termsDigest]) revert TermsNotPosted();
  }

  /// @notice reverts if the caller is not the signatory of the side
  /// @param terms the side's terms whose assets would be pulled
  function _enforceSignatoryCaller(Terms calldata terms) internal view {
    if (msg.sender != terms.signatory) revert CallerNotSignatory();
  }

  /// @notice generates a lock from a secret
  /// @param secret the preimage
  /// @return lock the hash of the secret
  function _generateLock(bytes32 secret) internal pure returns (bytes32 lock) {
    lock = EfficientHashLib.hash(secret);
  }
}
