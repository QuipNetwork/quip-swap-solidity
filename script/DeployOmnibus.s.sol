// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {Omnibus} from '../src/Omnibus.sol';
import {IDeployer} from '../src/interfaces/IDeployer.sol';
import {Constants} from './Constants.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';
import {CREATE3} from 'solady-0.1.26/utils/CREATE3.sol';

/**
 * @title DeployOmnibus
 * @dev Deploys the Omnibus singleton via the Deployer contract using CREATE3
 *      (solady's `CREATE3.deployDeterministic`). Omnibus address depends only
 *      on (Deployer address, salt) — same on every chain, independent of the
 *      broadcasting EOA and of constructor args. Owner differs per chain but
 *      the address doesn't.
 *
 *      Per-chain deploy order is CROSS-REPO: Deployer → ShrincsVerifier
 *      (deployed by hashsigs-solidity's DeployShrincsVerifier — the artifact
 *      owner) → Omnibus (this script). The verifier is consumed as a pinned
 *      (address, runtime codehash) pair from hashsigs' release registry and
 *      verified below before being trusted at construction.
 *
 * Usage:
 *   forge script script/DeployOmnibus.s.sol \
 *       --rpc-url $RPC --private-key $DEPLOYER_PK --broadcast --verify
 *
 * Environment:
 *   DEPLOYER_PK      - Operations wallet private key (broadcasting EOA)
 *   DEPLOYER_ADDRESS - Deployer contract address (bootstrapped via DeployDeployer)
 *   OMNIBUS_OWNER    - Initial owner of the Omnibus (Ownable2Step)
 */
contract DeployOmnibus is Script {
  bytes32 internal constant SALT = Constants.OMNIBUS_SALT;

  function run() external {
    address deployerAddr = vm.envAddress('DEPLOYER_ADDRESS');
    uint256 privateKey = vm.envUint('DEPLOYER_PK');
    address omnibusOwner = vm.envAddress('OMNIBUS_OWNER');

    require(deployerAddr.code.length > 0, 'Deployer not deployed. Run DeployDeployer first.');
    require(omnibusOwner != address(0), 'OMNIBUS_OWNER must be non-zero');

    address verifierAddr = Constants.SHRINCS_VERIFIER;
    // pins BOTH address and artifact; subsumes existence (empty/no account never matches)
    require(verifierAddr.codehash == Constants.SHRINCS_VERIFIER_CODEHASH, 'verifier: wrong or missing artifact');

    address expectedAddr = CREATE3.predictDeterministicAddress(SALT, deployerAddr);
    console.log('Deployer:          ', deployerAddr);
    console.log('Omnibus owner:     ', omnibusOwner);
    console.log('ShrincsVerifier:   ', verifierAddr);
    console.log('Expected Omnibus:  ', expectedAddr);

    if (expectedAddr.code.length > 0) {
      console.log('\nOmnibus already deployed. Skipping.');
      return;
    }

    address[] memory initialVerifiers = new address[](1);
    initialVerifiers[0] = verifierAddr;
    bytes memory bytecode = abi.encodePacked(type(Omnibus).creationCode, abi.encode(omnibusOwner, initialVerifiers));
    console.log('Bytecode size:', bytecode.length, 'bytes');

    vm.startBroadcast(privateKey);
    address deployed = IDeployer(deployerAddr).deploy(bytecode, SALT);
    vm.stopBroadcast();

    require(deployed == expectedAddr, 'Omnibus address mismatch');
    require(Omnibus(payable(deployed)).owner() == omnibusOwner, 'Omnibus owner mismatch');
    require(Omnibus(payable(deployed)).trustedVerifiers(verifierAddr), 'Omnibus does not trust ShrincsVerifier');
    console.log('Omnibus deployed at:', deployed);
  }
}
