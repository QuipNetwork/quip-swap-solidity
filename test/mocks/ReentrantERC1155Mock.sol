// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ERC1155} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/ERC1155.sol';
import {ERC1155Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/utils/ERC1155Holder.sol';

contract ReentrantERC1155Mock is ERC1155 {
  address public target;
  bytes public reentryCall;
  bool public armed;
  bool public reentered;
  bool public innerSucceeded;

  constructor() ERC1155('') {}

  function mint(address to, uint256 id, uint256 amount) external {
    _mint(to, id, amount, '');
  }

  function arm(address nextTarget, bytes calldata callData) external {
    target = nextTarget;
    reentryCall = callData;
    armed = true;
  }

  function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data) public override {
    super.safeTransferFrom(from, to, id, amount, data);
    if (armed && msg.sender == target) {
      armed = false;
      reentered = true;
      (innerSucceeded,) = target.call(reentryCall);
    }
  }
}

contract ReentrantERC1155Recipient is ERC1155Holder {
  address public target;
  bytes public reentryCall;
  bool public armed;
  bool public reentered;
  bool public innerSucceeded;

  function arm(address nextTarget, bytes calldata callData) external {
    target = nextTarget;
    reentryCall = callData;
    armed = true;
  }

  function onERC1155Received(
    address operator,
    address from,
    uint256 id,
    uint256 value,
    bytes memory data
  ) public override returns (bytes4) {
    if (armed) {
      armed = false;
      reentered = true;
      (innerSucceeded,) = target.call(reentryCall);
    }
    return super.onERC1155Received(operator, from, id, value, data);
  }
}
