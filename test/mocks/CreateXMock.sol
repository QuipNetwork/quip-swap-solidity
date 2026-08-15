// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CREATE3} from 'solady-0.1.26/utils/CREATE3.sol';

contract CreateXMock {
  function deployCreate3(bytes32 salt, bytes calldata initCode) external payable returns (address deployed) {
    // The cast intentionally reads the sender-permission prefix (the first 20 bytes).
    // forge-lint: disable-next-line(unsafe-typecast)
    require(address(bytes20(salt)) == msg.sender, 'invalid sender prefix');
    bytes32 guarded = keccak256(abi.encodePacked(bytes32(uint256(uint160(msg.sender))), salt));
    deployed = CREATE3.deployDeterministic(msg.value, initCode, guarded);
  }
}
