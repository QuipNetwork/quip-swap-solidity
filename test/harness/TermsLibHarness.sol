// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, PartyTerms, QuipTerms, TermsLib} from '../../src/TermsLib.sol';
import {IERC1155Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155Receiver.sol';
import {IERC721Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721Receiver.sol';

/// @title TermsLib Harness
/// @dev Wrapper contract to expose TermsLib library functions for testing
contract TermsLibHarness is IERC721Receiver, IERC1155Receiver {
  /// @notice Exposes validateAsset
  function exposed_validateAsset(Asset memory asset) external pure {
    TermsLib.validateAsset(asset);
  }

  /// @notice Exposes digestPartyTerms
  function exposed_digestPartyTerms(PartyTerms calldata terms) external pure returns (bytes32) {
    return TermsLib.digestPartyTerms(terms);
  }

  /// @notice Exposes digestTermsCanonically
  function exposed_digestTermsCanonically(QuipTerms calldata terms) external pure returns (bytes32) {
    return TermsLib.digestTermsCanonically(terms);
  }

  /// @notice Exposes digestTermsCanonicallyMemory
  function exposed_digestTermsCanonicallyMemory(QuipTerms memory terms) external pure returns (bytes32) {
    return TermsLib.digestTermsCanonicallyMemory(terms);
  }

  /// @notice Exposes coupleTerms
  function exposed_coupleTerms(
    PartyTerms calldata party,
    PartyTerms calldata counterparty
  ) external pure returns (QuipTerms memory) {
    return TermsLib.coupleTerms(party, counterparty);
  }

  /// @notice Exposes verifyTerms
  function exposed_verifyTerms(bytes32 termsDigest, QuipTerms calldata terms) external pure {
    TermsLib.verifyTerms(termsDigest, terms);
  }

  /// @notice Exposes transferAsset
  function exposed_transferAsset(Asset memory asset, address from, address to) external {
    TermsLib.transferAsset(asset, from, to);
  }

  /// @notice Exposes transferAssets
  function exposed_transferAssets(Asset[] memory assets, address from, address to) external {
    TermsLib.transferAssets(assets, from, to);
  }

  /// @notice Exposes transferAssetsNoNative
  function exposed_transferAssetsNoNative(Asset[] memory assets, address from, address to) external {
    TermsLib.transferAssetsNoNative(assets, from, to);
  }

  /// @notice Exposes executePartyCommitment
  function exposed_executePartyCommitment(
    address quip,
    address counterpartyRecipient,
    Asset[] calldata partyAssets
  ) external {
    TermsLib.executePartyCommitment(quip, counterpartyRecipient, partyAssets);
  }

  /// @notice Exposes releasePartyCommitment
  function exposed_releasePartyCommitment(address quip, address partyRecipient, Asset[] calldata partyAssets) external {
    TermsLib.releasePartyCommitment(quip, partyRecipient, partyAssets);
  }

  /// @notice Exposes totalNativeAmount
  function exposed_totalNativeAmount(Asset[] memory assets) external pure returns (uint256) {
    return TermsLib.totalNativeAmount(assets);
  }

  /// @notice Exposes enforceTermFreshness
  function exposed_enforceTermFreshness(uint64 expiry) external view {
    TermsLib.enforceTermFreshness(expiry);
  }

  /// @notice Exposes enforceTermStaleness
  function exposed_enforceTermStaleness(uint64 expiry) external view {
    TermsLib.enforceTermStaleness(expiry);
  }

  /// @notice Allows receiving native currency for transfer tests
  receive() external payable {}

  /// @notice ERC721 receiver hook
  function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
    return IERC721Receiver.onERC721Received.selector;
  }

  /// @notice ERC1155 receiver hook for single transfers
  function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
    return IERC1155Receiver.onERC1155Received.selector;
  }

  /// @notice ERC1155 receiver hook for batch transfers
  function onERC1155BatchReceived(
    address,
    address,
    uint256[] calldata,
    uint256[] calldata,
    bytes calldata
  ) external pure returns (bytes4) {
    return IERC1155Receiver.onERC1155BatchReceived.selector;
  }

  /// @notice ERC165 supportsInterface
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return interfaceId == type(IERC721Receiver).interfaceId || interfaceId == type(IERC1155Receiver).interfaceId;
  }
}
