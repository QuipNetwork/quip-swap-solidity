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
    // cannot commit to a spent lock
    if (lockState[lock] == LockState.Spent) revert LockAlreadySpent();

    // determine caller's terms
    bool isParty = msg.sender == party.signatory;
    bool isCounterparty = msg.sender == counterparty.signatory;
    if (!isParty && !isCounterparty) revert InvalidSignatory();

    TermsV0 calldata callerTerms = isParty ? party : counterparty;

    // compute canonical hash
    bytes32 hash = TermsLib.digestTermsV0Canonically(party, counterparty);

    // store or verify terms hash
    if (lockState[lock] == LockState.Unused) {
      termsHash[lock] = hash;
    } else {
      // lockState is Free - verify terms match
      if (termsHash[lock] != hash) revert InvalidTerms();
    }

    // verify deadline not passed
    TermsLib.enforceTermFreshness(callerTerms.deadline);

    // calculate expected native amount (collateral + assets)
    uint256 expectedNative = _nativeAmount(callerTerms.collateral) + TermsLib.totalNativeAmount(callerTerms.assets);
    if (msg.value != expectedNative) revert InsufficientCommitment();

    // transfer collateral (non-native)
    if (callerTerms.collateral.assetType != AssetType.Native) {
      TermsLib.transferAsset(callerTerms.collateral, msg.sender, address(this));
    }

    // transfer assets (non-native)
    TermsLib.transferAssetsNoNative(callerTerms.assets, msg.sender, address(this));

    // advance lock state: Unused → Free, Free → Spent
    lockState[lock] = lockState[lock] == LockState.Unused ? LockState.Free : LockState.Spent;

    emit Commitment(lock, msg.sender);
  }

  /// @inheritdoc IOmnibus
  function execute(bytes32 secret, TermsV0 calldata party, TermsV0 calldata counterparty) external {
    // compute lock from secret
    bytes32 lock = keccak256(abi.encodePacked(secret));

    // verify terms
    if (termsHash[lock] != TermsLib.digestTermsV0Canonically(party, counterparty)) revert InvalidTerms();

    // determine caller's terms and counterparty's recipient
    bool isParty = msg.sender == party.signatory;
    bool isCounterparty = msg.sender == counterparty.signatory;
    if (!isParty && !isCounterparty) revert InvalidSignatory();

    TermsV0 calldata callerTerms = isParty ? party : counterparty;
    address counterpartyRecipient = isParty ? counterparty.recipient : party.recipient;

    // verify caller's deadline not expired
    TermsLib.enforceTermFreshness(callerTerms.deadline);

    // delete terms hash to prevent replay
    delete termsHash[lock];

    // transfer caller's assets to counterparty's recipient
    TermsLib.transferAssets(callerTerms.assets, address(this), counterpartyRecipient);

    // return caller's collateral to caller's signatory
    TermsLib.transferAsset(callerTerms.collateral, address(this), callerTerms.signatory);

    emit Claim(lock, msg.sender, secret);
  }

  /// @inheritdoc IOmnibus
  function slash(bytes32 lock, TermsV0 calldata party, TermsV0 calldata counterparty) external {
    // verify terms
    if (termsHash[lock] != TermsLib.digestTermsV0Canonically(party, counterparty)) revert InvalidTerms();

    // determine target: caller must be counterparty's recipient to slash party
    bool slashingParty = msg.sender == counterparty.recipient;
    bool slashingCounterparty = msg.sender == party.recipient;
    if (!slashingParty && !slashingCounterparty) revert UnauthorizedSlasher();

    TermsV0 calldata target = slashingParty ? party : counterparty;

    // verify target's deadline has passed
    TermsLib.enforceTermStaleness(target.deadline);

    // delete terms hash
    delete termsHash[lock];

    // transfer target's collateral to slasher
    TermsLib.transferAsset(target.collateral, address(this), msg.sender);

    // return target's assets to target's recipient (graceful return)
    TermsLib.transferAssets(target.assets, address(this), target.recipient);

    emit Slashed(lock, target.signatory, msg.sender);
  }

  /// @inheritdoc IOmnibus
  function reclaim(bytes32 lock, TermsV0 calldata party, TermsV0 calldata counterparty) external {
    // verify terms
    if (termsHash[lock] != TermsLib.digestTermsV0Canonically(party, counterparty)) revert InvalidTerms();

    // can only reclaim when one party has committed
    if (lockState[lock] != LockState.Free) revert InvalidLockState();

    // determine caller's terms
    bool isParty = msg.sender == party.signatory;
    bool isCounterparty = msg.sender == counterparty.signatory;
    if (!isParty && !isCounterparty) revert InvalidSignatory();

    TermsV0 calldata callerTerms = isParty ? party : counterparty;

    // verify caller's deadline not expired (can only reclaim before deadline)
    TermsLib.enforceTermFreshness(callerTerms.deadline);

    // delete terms hash
    delete termsHash[lock];

    // return caller's assets + collateral to caller's signatory
    TermsLib.transferAssets(callerTerms.assets, address(this), callerTerms.signatory);
    TermsLib.transferAsset(callerTerms.collateral, address(this), callerTerms.signatory);

    emit Reclaimed(lock, msg.sender);
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

  /// @notice returns native amount from an asset (0 if not native)
  function _nativeAmount(Asset calldata asset) internal pure returns (uint256) {
    return asset.assetType == AssetType.Native ? asset.amount : 0;
  }
}
