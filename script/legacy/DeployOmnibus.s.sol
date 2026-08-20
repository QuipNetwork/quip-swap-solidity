// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {Omnibus} from '../../src/legacy/Omnibus.sol';
import {ICreateX} from '../ICreateX.sol';
import {Constants} from './Constants.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';

/**
 * @title DeployOmnibus
 * @dev Deploys the Omnibus singleton via the canonical CreateX factory using
 *      CREATE3. The address depends only on (CreateX, deployer EOA, salt) —
 *      same on every chain provided the SAME ops EOA broadcasts, independent
 *      of constructor args. Owner differs per chain but the address doesn't.
 *
 *      The salt is CreateX-permissioned (first 20 bytes = the broadcasting
 *      EOA), so nobody else can claim the address on any chain. No per-chain
 *      bootstrap is needed: CreateX is pre-deployed everywhere. Verifier
 *      activation is a separate, post-deploy owner action (setVerifierActivity).
 *
 *      Local rehearsal: bare Anvil has no CreateX — rehearse against a fork
 *      of a chain that does (`make anvil-fork RPC=...`).
 *
 * Usage:
 *   forge script script/legacy/DeployOmnibus.s.sol \
 *       --rpc-url $RPC --private-key $DEPLOYER_PK --broadcast --verify
 *
 * Environment:
 *   DEPLOYER_PK    - Operations wallet private key (broadcasting EOA; the salt
 *                    is permissioned to this EOA, so it pins the address)
 *   OMNIBUS_OWNER  - Initial owner of the Omnibus (Ownable2Step)
 *   WALLET_FACTORY - The quip WalletFactory proxy on this chain (baked as an
 *                    immutable; gates the wallet commit route)
 */
contract DeployOmnibus is Script {
  function run() external {
    uint256 privateKey = vm.envUint('DEPLOYER_PK');
    address omnibusOwner = vm.envAddress('OMNIBUS_OWNER');
    address walletFactory = vm.envAddress('WALLET_FACTORY');
    address deployerEoa = vm.addr(privateKey);

    require(Constants.CREATEX.code.length > 0, 'CreateX not deployed on this chain');
    require(omnibusOwner != address(0), 'OMNIBUS_OWNER must be non-zero');
    require(walletFactory != address(0), 'WALLET_FACTORY must be non-zero');

    address expectedAddr = Constants.predictOmnibus(deployerEoa);
    console.log('Deployer EOA:      ', deployerEoa);
    console.log('Omnibus owner:     ', omnibusOwner);
    console.log('Wallet factory:    ', walletFactory);
    console.log('Expected Omnibus:  ', expectedAddr);

    if (expectedAddr.code.length > 0) {
      console.log('\nOmnibus already deployed. Skipping.');
      return;
    }

    bytes memory bytecode = abi.encodePacked(type(Omnibus).creationCode, abi.encode(omnibusOwner, walletFactory));

    vm.startBroadcast(privateKey);
    address deployed = ICreateX(Constants.CREATEX).deployCreate3(Constants.omnibusSalt(deployerEoa), bytecode);
    vm.stopBroadcast();

    require(deployed == expectedAddr, 'Omnibus address mismatch');
    require(Omnibus(payable(deployed)).owner() == omnibusOwner, 'Omnibus owner mismatch');
    console.log('Omnibus deployed at:', deployed);
  }
}
