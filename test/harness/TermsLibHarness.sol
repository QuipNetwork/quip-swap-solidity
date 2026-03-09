// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, Terms, TermsLib} from '../../src/TermsLib.sol';
import {IERC1155Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155Receiver.sol';
import {IERC721Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721Receiver.sol';

/// @title TermsLib Harness
/// @dev Wrapper contract to expose TermsLib library functions for testing
contract TermsLibHarness is IERC721Receiver, IERC1155Receiver {
  /// @notice exposes validateAsset
  function exposed_validateAsset(Asset memory asset) external pure {
    TermsLib.validateAsset(asset);
  }

  /// @notice exposes digestTermsCanonically
  function exposed_digestTermsCanonically(
    Terms calldata party,
    Terms calldata counterparty
  ) external pure returns (bytes32) {
    return TermsLib.digestTermsCanonically(party, counterparty);
  }

  /// @notice exposes validateTerms
  function exposed_validateTerms(Terms calldata party, Terms calldata counterparty) external view {
    TermsLib.validateTerms(party, counterparty);
  }

  /// @notice exposes transferAsset
  function exposed_transferAsset(Asset memory asset, address from, address to) external {
    TermsLib.transferAsset(asset, from, to);
  }

  /// @notice exposes transferAssets
  function exposed_transferAssets(Asset[] memory assets, address from, address to) external {
    TermsLib.transferAssets(assets, from, to);
  }

  /// @notice exposes transferAssetsNoNative
  function exposed_transferAssetsNoNative(Asset[] memory assets, address from, address to) external {
    TermsLib.transferAssetsNoNative(assets, from, to);
  }

  /// @notice exposes transferNonNativeAssetsIn
  function exposed_transferNonNativeAssetsIn(Terms calldata terms, address from, address to) external {
    TermsLib.transferNonNativeAssetsIn(terms, from, to);
  }

  /// @notice exposes totalNativeAmount
  function exposed_totalNativeAmount(Asset[] memory assets) external pure returns (uint256) {
    return TermsLib.totalNativeAmount(assets);
  }

  /// @notice exposes totalNativeAmountFromTerms
  function exposed_totalNativeAmountFromTerms(Terms calldata terms) external pure returns (uint256) {
    return TermsLib.totalNativeAmountFromTerms(terms);
  }

  /// @notice exposes enforceTermFreshness
  function exposed_enforceTermFreshness(Terms calldata terms) external view {
    TermsLib.enforceTermFreshness(terms);
  }

  /// @notice exposes enforceTermStaleness
  function exposed_enforceTermStaleness(uint64 expiry) external view {
    TermsLib.enforceTermStaleness(expiry);
  }

  /// @notice exposes generateLock
  function exposed_generateLock(bytes32 secret) external pure returns (bytes32) {
    return TermsLib.generateLock(secret);
  }

  /// @notice allows receiving native currency for transfer tests
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
