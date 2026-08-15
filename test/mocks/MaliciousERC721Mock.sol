// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ERC721} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/ERC721.sol';

contract MaliciousERC721Mock is ERC721 {
  enum Behavior {
    Exact,
    NoOp
  }

  Behavior public behavior;

  constructor() ERC721('Malicious NFT', 'MNFT') {}

  function mint(address to, uint256 tokenId) external {
    _mint(to, tokenId);
  }

  function setBehavior(Behavior next) external {
    behavior = next;
  }

  function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public override {
    if (behavior == Behavior.NoOp) return;
    super.safeTransferFrom(from, to, tokenId, data);
  }
}
