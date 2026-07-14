// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IDeployer} from '../../src/interfaces/IDeployer.sol';
import {CREATE3} from 'solady-0.1.26/utils/CREATE3.sol';

/// @title Deployer Mock
/// @dev minimal IDeployer for LOCAL deploy-script rehearsals (anvil): same CREATE3
/// math as the production Deployer, so DeployShrincsVerifier/DeployOmnibus predict
/// and deploy against it exactly as they do against the real one
contract DeployerMock is IDeployer {
  function deploy(bytes memory bytecode, bytes32 salt) external returns (address addr) {
    addr = CREATE3.deployDeterministic(bytecode, salt);
    emit Deploy(addr);
  }

  function predictAddress(bytes32 salt) external view returns (address) {
    return CREATE3.predictDeterministicAddress(salt);
  }
}
