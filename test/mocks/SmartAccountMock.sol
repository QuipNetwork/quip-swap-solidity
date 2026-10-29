// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

/// @title Smart Account Mock
/// @dev Minimal stand-in for a smart account (e.g. a quip wallet) in the SDK
/// integration suite: it executes an arbitrary `{to, value, data}` Call from
/// its OWN address and balance, exactly as a wallet's `execute` would after
/// verifying its signature. No authorization — signature verification is the
/// real wallet's concern and is out of scope for what this proves, namely
/// that a Call planned by the SDK for `account = this` runs with `msg.sender
/// == this` and is funded by this contract's ETH and tokens. Deployable
/// (no cheatcodes) because the SDK suite runs it on Anvil.
contract SmartAccountMock {
  error ExecutionFailed(bytes result);

  receive() external payable {}

  function execute(address to, uint256 value, bytes calldata data) external returns (bytes memory result) {
    bool ok;
    (ok, result) = to.call{value: value}(data);
    if (!ok) revert ExecutionFailed(result);
  }
}
