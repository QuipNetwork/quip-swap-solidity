// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

/// @notice Native-asset recipient that attempts one nested call without
/// reverting the outer payout.
contract ReentrantRecipient {
  address public target;
  bytes public payload;
  bool public reentered;
  bool public innerSucceeded;

  function arm(address nextTarget, bytes memory nextPayload) external {
    target = nextTarget;
    payload = nextPayload;
  }

  receive() external payable {
    if (reentered || target == address(0)) return;
    reentered = true;
    (innerSucceeded,) = target.call(payload);
  }
}
