// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IERC1271} from '@openzeppelin-contracts-5.6.0-rc.1/interfaces/IERC1271.sol';

/// @title ERC-1271 Mock
/// @dev test double for the has-code commit route. Any 20-byte identity WITH code
/// routes unconditionally to `isValidSignature`. Deliberately NOT declared view
/// (and not `is IERC1271`): the router calls through the view interface — a
/// STATICCALL — so the AttemptWrite mode's state write reverts, PROVING the router
/// staticcalls 1271; the other modes touch no state and behave normally.
contract Erc1271Mock {
  enum Mode {
    /// @notice returns the ERC-1271 magic value
    Accept,
    /// @notice returns a non-magic selector
    WrongMagic,
    /// @notice reverts
    Revert,
    /// @notice attempts a state write (reverts under STATICCALL — proves the router staticcalls)
    AttemptWrite
  }

  Mode public mode;
  uint256 public writes;

  function setMode(Mode newMode) external {
    mode = newMode;
  }

  function isValidSignature(bytes32, bytes memory) public returns (bytes4) {
    if (mode == Mode.Accept) return IERC1271.isValidSignature.selector;
    if (mode == Mode.WrongMagic) return bytes4(0xdeadbeef);
    if (mode == Mode.Revert) revert('Erc1271Mock: revert mode');
    // AttemptWrite: an SSTORE inside the router's STATICCALL context reverts
    ++writes;
    return IERC1271.isValidSignature.selector;
  }
}
