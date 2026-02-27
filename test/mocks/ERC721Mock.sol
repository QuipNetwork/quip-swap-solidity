// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ERC721} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/ERC721.sol';

contract ERC721Mock is ERC721 {
  uint256 private _nextTokenId;

  constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

  function mint(address to) external returns (uint256 tokenId) {
    tokenId = ++_nextTokenId;
    _mint(to, tokenId);
  }

  function mint(address to, uint256 tokenId) external {
    _mint(to, tokenId);
  }

  function burn(uint256 tokenId) external {
    _burn(tokenId);
  }
}
