// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

enum Status {
  Open,
  Accepted,
  Committed,
  Claimed,
  Reclaimed,
  Slashed
}

enum AssetType {
  Native,
  ERC20,
  ERC721,
  ERC1155
}

struct Asset {
  AssetType assetType;
  address target;
  uint256 id;
  uint256 amount;
}

struct QuipTerms {
  address party;
  address partyRecipient;
  address counterparty;
  address counterpartyRecipient;
  uint64 partyExpiry;
  uint64 counterpartyExpiry;
  Asset[] partyAssets;
  Asset[] counterpartyAssets;
}

interface IQuip {
  function version() external view returns (uint256);
  function initialize(bytes32 secretDigest, QuipTerms calldata terms) external;
}
