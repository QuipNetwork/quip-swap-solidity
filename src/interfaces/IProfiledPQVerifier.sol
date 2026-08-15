// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

interface IProfiledPQVerifier {
  function VERSION_TAG() external view returns (bytes32);

  function PROFILE_TAG() external view returns (bytes32);
}
