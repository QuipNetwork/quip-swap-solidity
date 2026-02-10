// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Script, console} from 'forge-std-1.14.0/Script.sol';

import {Quip} from '../src/Quip.sol';
import {QuipPortal} from '../src/QuipPortal.sol';

/// @title Deploy QuipPortal
/// @notice Deploys the Quip implementation and QuipPortal factory
/// @dev Run with: forge script script/DeployQuipPortal.s.sol --rpc-url $RPC_URL --broadcast --verify
///
/// Required environment variables:
///   DEPLOYER_PK - Private key for deployment
///   PORTAL_ADMIN - Admin address for fee management
///   PORTAL_MAX_FEE - Maximum fee cap in wei
///   PORTAL_CREATION_FEE - Initial creation fee in wei
contract DeployQuipPortal is Script {
  function run() external {
    uint256 deployerPk = vm.envUint('DEPLOYER_PK');
    address portalAdmin = vm.envAddress('PORTAL_ADMIN');
    uint256 maxFee = vm.envUint('PORTAL_MAX_FEE');
    uint256 creationFee = vm.envUint('PORTAL_CREATION_FEE');

    console.log('=== Configuration ===');
    console.log('Admin:', portalAdmin);
    console.log('Max Fee:', maxFee);
    console.log('Creation Fee:', creationFee);

    vm.startBroadcast(deployerPk);

    Quip quipImpl = new Quip();
    console.log('Quip implementation deployed at:', address(quipImpl));

    QuipPortal portal = new QuipPortal(portalAdmin, address(quipImpl), maxFee, creationFee);
    console.log('QuipPortal deployed at:', address(portal));

    vm.stopBroadcast();

    console.log('=== Deployment Complete ===');
    console.log('Quip Implementation:', address(quipImpl));
    console.log('QuipPortal:', address(portal));
  }
}
