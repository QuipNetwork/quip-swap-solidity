// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {Omnibus} from '../src/legacy/Omnibus.sol';
import {Constants} from './Constants.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';

/**
 * @title ActivateVerifier
 * @dev Activates an ERC-7913 verifier on the deployed Omnibus
 *      (`setVerifierActivity(verifier, true)`) — the post-deploy OWNER action
 *      that enables keyed commit authorization through that verifier.
 *
 *      The verifier is passed as a script ARGUMENT (via `--sig`). The Omnibus
 *      address is never passed in: it is predictable, so the script computes
 *      it from (CreateX, DEPLOYER_ADDRESS, salt) — the same math DeployOmnibus
 *      uses.
 *
 *      Idempotent: if the verifier is already active, logs and exits without
 *      broadcasting.
 *
 * Usage:
 *   forge script script/ActivateVerifier.s.sol \
 *       --sig 'run(address)' <VERIFIER_ADDRESS> \
 *       --rpc-url $RPC --broadcast
 *
 * Environment:
 *   OMNIBUS_OWNER_PK - Private key of the Omnibus owner (broadcasting EOA;
 *                      setVerifierActivity is onlyOwner)
 *   DEPLOYER_ADDRESS - Deployer EOA, used to predict the Omnibus address
 */
contract ActivateVerifier is Script {
  function run(address verifier) external {
    uint256 ownerPk = vm.envUint('OMNIBUS_OWNER_PK');
    address omnibusAddr = Constants.predictOmnibus(vm.envAddress('DEPLOYER_ADDRESS'));
    Omnibus omnibus = Omnibus(payable(omnibusAddr));

    require(omnibusAddr.code.length > 0, 'Omnibus not deployed at predicted address');
    require(verifier.code.length > 0, 'Verifier not deployed on this chain');
    require(omnibus.owner() == vm.addr(ownerPk), 'OMNIBUS_OWNER_PK is not the Omnibus owner');

    console.log('Omnibus:  ', omnibusAddr);
    console.log('Verifier: ', verifier);

    if (omnibus.verifierActive(verifier)) {
      console.log('\nVerifier already active. Skipping.');
      return;
    }

    vm.startBroadcast(ownerPk);
    omnibus.setVerifierActivity(verifier, true);
    vm.stopBroadcast();

    require(omnibus.verifierActive(verifier), 'Verifier activation failed');
    console.log('Verifier activated.');
  }
}
