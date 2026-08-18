// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ERC721} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/ERC721.sol';

contract MaliciousERC721Mock is ERC721 {
  enum Behavior {
    Exact,
    NoOp,
    OwnerQueryReverts,
    OwnerQueryWrong,
    TransferThenOwnerQueryReverts,
    TransferThenOwnerQueryWrong
  }

  Behavior public behavior;
  address internal constant WRONG_OWNER = address(0xBAD);

  constructor() ERC721('Malicious NFT', 'MNFT') {}

  function mint(address to, uint256 tokenId) external {
    _mint(to, tokenId);
  }

  function setBehavior(Behavior next) external {
    behavior = next;
  }

  function actualOwnerOf(uint256 tokenId) external view returns (address) {
    return _ownerOf(tokenId);
  }

  function ownerOf(uint256 tokenId) public view override returns (address) {
    if (behavior == Behavior.OwnerQueryReverts) revert('OWNER_QUERY_REVERTED');
    if (behavior == Behavior.OwnerQueryWrong) return WRONG_OWNER;
    return super.ownerOf(tokenId);
  }

  function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public override {
    if (behavior == Behavior.NoOp) return;
    super.safeTransferFrom(from, to, tokenId, data);
    if (behavior == Behavior.TransferThenOwnerQueryReverts) behavior = Behavior.OwnerQueryReverts;
    if (behavior == Behavior.TransferThenOwnerQueryWrong) behavior = Behavior.OwnerQueryWrong;
  }
}
