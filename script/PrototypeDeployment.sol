// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CREATE3} from 'solady-0.1.26/utils/CREATE3.sol';

/// @notice Deterministic deployment identifiers for the v1.1 prototype.
/// @dev Addresses depend on the CreateX factory, broadcasting EOA and component
///      identifier, but not constructor arguments. Bump VERSION for a new set.
library PrototypeDeployment {
  string internal constant VERSION = 'v1.1.0-alpha.4';
  address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

  enum Component {
    AssetSupportRegistry,
    DirectAuthorization,
    CrossChainWrapper,
    SameChainWrapper,
    SwapHTLC
  }

  function salt(address deployer, Component component) internal pure returns (bytes32) {
    bytes11 entropy = bytes11(keccak256(abi.encodePacked('QUIP:Swap:', VERSION, ':', uint8(component))));
    return bytes32(abi.encodePacked(deployer, hex'00', entropy));
  }

  function guardedSalt(address deployer, Component component) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), salt(deployer, component)));
  }

  function predict(address factory, address deployer, Component component) internal pure returns (address) {
    return CREATE3.predictDeterministicAddress(guardedSalt(deployer, component), factory);
  }
}
