// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ERC20} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC20/ERC20.sol';

contract MaliciousERC20Mock is ERC20 {
  enum Behavior {
    Exact,
    NoOp,
    OverCredit,
    ReturnFalse
  }

  Behavior public behavior;

  constructor() ERC20('Malicious', 'MAL') {}

  function setBehavior(Behavior value) external {
    behavior = value;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  function transfer(address to, uint256 amount) public override returns (bool) {
    if (behavior == Behavior.NoOp) return true;
    if (behavior == Behavior.ReturnFalse) return false;
    bool success = super.transfer(to, amount);
    if (behavior == Behavior.OverCredit) _mint(to, 1);
    return success;
  }

  function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
    if (behavior == Behavior.NoOp) return true;
    if (behavior == Behavior.ReturnFalse) return false;
    bool success = super.transferFrom(from, to, amount);
    if (behavior == Behavior.OverCredit) _mint(to, 1);
    return success;
  }
}
