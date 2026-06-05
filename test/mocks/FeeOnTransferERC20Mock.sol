// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ERC20} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC20/ERC20.sol';

/// @title Fee-on-transfer ERC20 Mock
/// @dev skims a fixed basis-point fee on every transfer, so the recipient receives
/// less than the requested amount; used to test escrow balance reconciliation
contract FeeOnTransferERC20Mock is ERC20 {
  /// @notice fee in basis points taken from each transfer (e.g. 100 = 1%)
  uint256 public immutable FEE_BPS;

  constructor(string memory name_, string memory symbol_, uint256 feeBps_) ERC20(name_, symbol_) {
    FEE_BPS = feeBps_;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  /// @dev burns the fee from the transferred amount so the recipient gets `amount - fee`
  function _update(address from, address to, uint256 amount) internal override {
    if (from == address(0) || to == address(0) || FEE_BPS == 0) {
      super._update(from, to, amount);
      return;
    }
    uint256 fee = (amount * FEE_BPS) / 10_000;
    super._update(from, to, amount - fee);
    super._update(from, address(0), fee); // burn the skimmed fee
  }
}
