// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {IDeployer} from '../src/interfaces/IDeployer.sol';
import {Constants} from './Constants.sol';
import {ShrincsVerifier} from '@quip.network/hashsigs-solidity-0.2.0/contracts/ShrincsVerifier.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';
import {CREATE3} from 'solady-0.1.26/utils/CREATE3.sol';

/**
 * @title DeployShrincsVerifier
 * @dev Deploys the stateful SHRINCS ERC-7913 verifier singleton via the Deployer
 *      contract using CREATE3. The verifier is trustless by construction (no
 *      owner, no storage, no constructor args), so the address depends only on
 *      (Deployer address, salt) — same on every chain.
 *
 *      Per-chain deploy order: Deployer → ShrincsVerifier → Omnibus.
 *      DeployOmnibus predicts this verifier's address from the same salt and
 *      requires code at it, then trusts it in the Omnibus constructor.
 *
 * Usage:
 *   forge script script/DeployShrincsVerifier.s.sol \
 *       --rpc-url $RPC --private-key $DEPLOYER_PK --broadcast --verify
 *
 * Environment:
 *   DEPLOYER_PK      - Operations wallet private key (broadcasting EOA)
 *   DEPLOYER_ADDRESS - Deployer contract address (bootstrapped via DeployDeployer)
 */
contract DeployShrincsVerifier is Script {
  bytes32 internal constant SALT = Constants.SHRINCS_VERIFIER_V1_SALT;

  function run() external {
    address deployerAddr = vm.envAddress('DEPLOYER_ADDRESS');
    uint256 privateKey = vm.envUint('DEPLOYER_PK');

    require(deployerAddr.code.length > 0, 'Deployer not deployed. Run DeployDeployer first.');

    address expectedAddr = CREATE3.predictDeterministicAddress(SALT, deployerAddr);
    console.log('Deployer:                  ', deployerAddr);
    console.log('Expected ShrincsVerifier:  ', expectedAddr);

    if (expectedAddr.code.length > 0) {
      console.log('\nShrincsVerifier already deployed. Skipping.');
      return;
    }

    // no constructor args: trustless by construction
    bytes memory bytecode = type(ShrincsVerifier).creationCode;
    console.log('Bytecode size:', bytecode.length, 'bytes');

    vm.startBroadcast(privateKey);
    address deployed = IDeployer(deployerAddr).deploy(bytecode, SALT);
    vm.stopBroadcast();

    require(deployed == expectedAddr, 'ShrincsVerifier address mismatch');
    console.log('ShrincsVerifier deployed at:', deployed);
    console.log('VERSION_TAG:');
    console.logBytes32(ShrincsVerifier(deployed).VERSION_TAG());
  }
}
