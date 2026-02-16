// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Script, console} from 'forge-std-1.14.0/Script.sol';
import {ICreateX} from 'pcaversaccio-createx-1.0.0/src/ICreateX.sol';

import {Quip} from '../src/Quip.sol';
import {QuipPortal} from '../src/QuipPortal.sol';

/// @title Deploy QuipPortal
/// @notice Deploys the Quip implementation and QuipPortal factory using CreateX
/// @dev Uses CREATE3 for truly chain-independent addresses (independent of constructor args)
///
/// Run with: forge script script/DeployQuipPortal.s.sol --rpc-url $RPC_URL --broadcast --verify
///
/// Required environment variables:
///   DEPLOYER_PK - Private key for deployment
///   PORTAL_ADMIN - Admin address for fee management
///   PORTAL_MAX_FEE - Maximum fee cap in wei
///   PORTAL_CREATION_FEE - Initial creation fee in wei
///
/// Deterministic Addresses (CREATE3):
///   Addresses depend ONLY on the CreateX factory address and the salt.
///   Constructor arguments do NOT affect the deployed address, allowing
///   different admins per chain while maintaining the same contract addresses.
contract DeployQuipPortal is Script {
  // ============ CreateX Factory ============

  /// @notice CreateX factory deployed on 60+ chains at this address
  /// @dev See https://createx.rocks for full chain list
  ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

  // ============ Salt Suffixes ============
  // Using 12-byte suffixes that get combined with deployer address for guarded salts

  bytes12 public constant SALT_SUFFIX_QUIP_IMPL = bytes12(keccak256('quip.network.QuipImpl.v1'));
  bytes12 public constant SALT_SUFFIX_QUIP_PORTAL = bytes12(keccak256('quip.network.QuipPortal.v1'));

  function run() external {
    uint256 deployerPk = vm.envUint('DEPLOYER_PK');
    address portalAdmin = vm.envAddress('PORTAL_ADMIN');
    uint256 maxFee = vm.envUint('PORTAL_MAX_FEE');
    uint256 creationFee = vm.envUint('PORTAL_CREATION_FEE');
    address deployer = vm.addr(deployerPk);

    console.log('=== Configuration ===');
    console.log('Deployer:', deployer);
    console.log('Admin:', portalAdmin);
    console.log('Max Fee:', maxFee);
    console.log('Creation Fee:', creationFee);
    console.log('CreateX Factory:', address(CREATEX));

    // Compute guarded salts (deployer address in first 20 bytes to prevent frontrunning)
    bytes32 saltQuipImpl = _computeGuardedSalt(deployer, SALT_SUFFIX_QUIP_IMPL);
    bytes32 saltQuipPortal = _computeGuardedSalt(deployer, SALT_SUFFIX_QUIP_PORTAL);

    // Compute expected addresses
    console.log('');
    console.log('=== Expected Addresses ===');
    address expectedQuipImpl = CREATEX.computeCreate3Address(saltQuipImpl, address(CREATEX));
    console.log('Quip Implementation:', expectedQuipImpl);

    address expectedPortal = CREATEX.computeCreate3Address(saltQuipPortal, address(CREATEX));
    console.log('QuipPortal:', expectedPortal);

    vm.startBroadcast(deployerPk);

    // Deploy Quip implementation via CREATE3
    bytes memory quipInitCode = type(Quip).creationCode;
    address quipImpl = CREATEX.deployCreate3(saltQuipImpl, quipInitCode);
    console.log('');
    console.log('Quip implementation deployed at:', quipImpl);

    // Deploy QuipPortal via CREATE3 (constructor args don't affect address)
    bytes memory portalInitCode =
      abi.encodePacked(type(QuipPortal).creationCode, abi.encode(portalAdmin, quipImpl, maxFee, creationFee));
    address portal = CREATEX.deployCreate3(saltQuipPortal, portalInitCode);
    console.log('QuipPortal deployed at:', portal);

    vm.stopBroadcast();

    console.log('');
    console.log('=== Deployment Complete ===');
    console.log('Quip Implementation:', quipImpl);
    console.log('QuipPortal:', portal);
    console.log('');
    console.log('NOTE: These addresses are deterministic across all EVM chains.');
    console.log('      Constructor arguments (admin, fees) do NOT affect the address.');
  }

  /// @notice Computes a guarded salt with deployer address in first 20 bytes
  /// @dev This prevents frontrunning by ensuring only the deployer can use this salt
  function _computeGuardedSalt(address deployer, bytes12 suffix) internal pure returns (bytes32) {
    return bytes32(abi.encodePacked(deployer, suffix));
  }
}
