// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../src/legacy/TermsLib.sol';
import {Asset} from '../../src/protocol/ProtocolTypes.sol';
import {IERC1155Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155Receiver.sol';
import {IERC721Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721Receiver.sol';

/// @title TermsLib Harness
/// @dev Wrapper contract to expose TermsLib library functions for testing
contract TermsLibHarness is IERC721Receiver, IERC1155Receiver {
  /// @notice exposes validateAsset
  function exposed_validateAsset(Asset memory asset) external pure {
    TermsLib.validateAsset(asset);
  }

  /// @notice exposes digestTerms
  function exposed_digestTerms(Terms calldata terms) external pure returns (bytes32) {
    return TermsLib.digestTerms(terms);
  }

  /// @notice exposes digestTermsCanonically
  function exposed_digestTermsCanonically(
    Terms calldata party,
    Terms calldata counterparty
  ) external pure returns (bytes32) {
    return TermsLib.digestTermsCanonically(party, counterparty);
  }

  /// @notice exposes validateTerms
  function exposed_validateTerms(Terms calldata terms) external pure {
    TermsLib.validateTerms(terms);
  }

  /// @notice exposes validateAssets
  function exposed_validateAssets(Terms calldata terms) external pure {
    TermsLib.validateAssets(terms);
  }

  /// @notice exposes enforceNonZeroChainId
  function exposed_enforceNonZeroChainId(Terms calldata terms) external pure {
    TermsLib.enforceNonZeroChainId(terms);
  }

  /// @notice exposes enforceChainId
  function exposed_enforceChainId(Terms calldata terms, uint256 chainId) external pure {
    TermsLib.enforceChainId(terms, chainId);
  }

  /// @notice exposes enforceWithin
  function exposed_enforceWithin(uint256 lower, uint256 upper, uint256 timestamp) external pure {
    TermsLib.enforceWithin(lower, upper, timestamp);
  }

  /// @notice exposes validateTermPairing
  function exposed_validateTermPairing(Terms calldata party, Terms calldata counterparty) external pure {
    TermsLib.validateTermPairing(party, counterparty);
  }

  /// @notice exposes proposedByParty
  function exposed_proposedByParty(Terms calldata party, Terms calldata counterparty) external pure returns (bool) {
    return TermsLib.proposedByParty(party, counterparty);
  }

  /// @notice exposes transferAsset
  function exposed_transferAsset(Asset memory asset, address from, address to) external {
    TermsLib.transferAsset(asset, from, to);
  }

  /// @notice exposes transferAssets
  function exposed_transferAssets(Terms calldata terms, address from, address to) external {
    TermsLib.transferAssets(terms, from, to);
  }

  /// @notice exposes transferAssetsNoNative
  function exposed_transferAssetsNoNative(Terms calldata terms, address from, address to) external {
    TermsLib.transferAssetsNoNative(terms, from, to);
  }

  /// @notice exposes totalNative
  function exposed_totalNative(Terms calldata terms) external pure returns (uint256) {
    return TermsLib.totalNative(terms);
  }

  /// @notice exposes heldBalance
  function exposed_heldBalance(Asset memory asset, address account) external view returns (uint256) {
    return TermsLib.heldBalance(asset, account);
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
