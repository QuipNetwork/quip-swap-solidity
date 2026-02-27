// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ERC1155} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/ERC1155.sol';

contract ERC1155Mock is ERC1155 {
  constructor(string memory uri_) ERC1155(uri_) {}

  function mint(address to, uint256 id, uint256 amount, bytes memory data) external {
    _mint(to, id, amount, data);
  }

  function mintBatch(address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data) external {
    _mintBatch(to, ids, amounts, data);
  }

  function burn(address from, uint256 id, uint256 amount) external {
    _burn(from, id, amount);
  }

  function burnBatch(address from, uint256[] memory ids, uint256[] memory amounts) external {
    _burnBatch(from, ids, amounts);
  }
}
