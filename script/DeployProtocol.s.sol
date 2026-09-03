// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetSupportRegistry} from '../src/assets/AssetSupportRegistry.sol';
import {DirectAuthorization} from '../src/authorization/direct/DirectAuthorization.sol';
import {CrossChainWrapper} from '../src/protocol/CrossChainWrapper.sol';
import {SameChainWrapper} from '../src/protocol/SameChainWrapper.sol';
import {SwapHTLC} from '../src/protocol/SwapHTLC.sol';
import {ICreateX} from './ICreateX.sol';
import {PrototypeDeployment} from './PrototypeDeployment.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';

/// @notice Deploys one complete v1.1 prototype stack through canonical CreateX.
contract DeployProtocol is Script {
  struct Addresses {
    address assetSupportRegistry;
    address directAuthorization;
    address crossChainWrapper;
    address sameChainWrapper;
    address swapHTLC;
  }

  event ProtocolDeployment(
    uint256 indexed chainId,
    string version,
    address indexed deployer,
    address owner,
    address trustedVerifier,
    Addresses addresses
  );

  function run() external returns (Addresses memory addresses) {
    uint256 privateKey = vm.envUint('DEPLOYER_PK');
    address deployer = vm.addr(privateKey);
    address owner = vm.envAddress('PROTOCOL_OWNER');
    address verifier = vm.envAddress('TRUSTED_VERIFIER');
    require(owner != address(0), 'PROTOCOL_OWNER must be non-zero');
    require(owner == deployer, 'PROTOCOL_OWNER must initially be deployer');
    require(PrototypeDeployment.CREATEX.code.length != 0, 'CreateX not deployed');
    require(verifier.code.length != 0, 'TRUSTED_VERIFIER not deployed');

    addresses = predicted(PrototypeDeployment.CREATEX, deployer);
    vm.startBroadcast(privateKey);
    _deploy(
      PrototypeDeployment.CREATEX,
      deployer,
      PrototypeDeployment.Component.AssetSupportRegistry,
      abi.encodePacked(type(AssetSupportRegistry).creationCode, abi.encode(owner)),
      addresses.assetSupportRegistry
    );
    _deploy(
      PrototypeDeployment.CREATEX,
      deployer,
      PrototypeDeployment.Component.DirectAuthorization,
      abi.encodePacked(type(DirectAuthorization).creationCode, abi.encode(verifier)),
      addresses.directAuthorization
    );
    _deploy(
      PrototypeDeployment.CREATEX,
      deployer,
      PrototypeDeployment.Component.SwapHTLC,
      type(SwapHTLC).creationCode,
      addresses.swapHTLC
    );
    _deploy(
      PrototypeDeployment.CREATEX,
      deployer,
      PrototypeDeployment.Component.CrossChainWrapper,
      abi.encodePacked(
        type(CrossChainWrapper).creationCode,
        abi.encode(addresses.directAuthorization, addresses.assetSupportRegistry, addresses.swapHTLC, owner)
      ),
      addresses.crossChainWrapper
    );
    _deploy(
      PrototypeDeployment.CREATEX,
      deployer,
      PrototypeDeployment.Component.SameChainWrapper,
      abi.encodePacked(
        type(SameChainWrapper).creationCode,
        abi.encode(addresses.directAuthorization, addresses.assetSupportRegistry, addresses.swapHTLC, owner)
      ),
      addresses.sameChainWrapper
    );
    vm.stopBroadcast();

    _verify(addresses, owner, verifier);
    emit ProtocolDeployment(block.chainid, PrototypeDeployment.VERSION, deployer, owner, verifier, addresses);
    _print(addresses, deployer, owner, verifier);
  }

  function predicted(address factory, address deployer) public pure returns (Addresses memory addresses) {
    addresses.assetSupportRegistry =
      PrototypeDeployment.predict(factory, deployer, PrototypeDeployment.Component.AssetSupportRegistry);
    addresses.directAuthorization =
      PrototypeDeployment.predict(factory, deployer, PrototypeDeployment.Component.DirectAuthorization);
    addresses.crossChainWrapper =
      PrototypeDeployment.predict(factory, deployer, PrototypeDeployment.Component.CrossChainWrapper);
    addresses.sameChainWrapper =
      PrototypeDeployment.predict(factory, deployer, PrototypeDeployment.Component.SameChainWrapper);
    addresses.swapHTLC = PrototypeDeployment.predict(factory, deployer, PrototypeDeployment.Component.SwapHTLC);
  }

  function _deploy(
    address factory,
    address deployer,
    PrototypeDeployment.Component component,
    bytes memory initCode,
    address expected
  ) internal {
    if (expected.code.length != 0) return;
    address deployed = ICreateX(factory).deployCreate3(PrototypeDeployment.salt(deployer, component), initCode);
    require(deployed == expected, 'CREATE3 address mismatch');
  }

  function _verify(Addresses memory a, address owner, address verifier) internal view {
    require(a.swapHTLC.code.length != 0, 'HTLC implementation missing');
    require(AssetSupportRegistry(a.assetSupportRegistry).owner() == owner, 'asset owner mismatch');
    require(CrossChainWrapper(payable(a.crossChainWrapper)).owner() == owner, 'cross owner mismatch');
    require(SameChainWrapper(payable(a.sameChainWrapper)).owner() == owner, 'same owner mismatch');
    require(DirectAuthorization(a.directAuthorization).TRUSTED_VERIFIER() == verifier, 'verifier mismatch');
    require(
      CrossChainWrapper(payable(a.crossChainWrapper)).DIRECT_AUTHORIZATION() == a.directAuthorization,
      'cross direct authorization mismatch'
    );
    require(
      SameChainWrapper(payable(a.sameChainWrapper)).DIRECT_AUTHORIZATION() == a.directAuthorization,
      'same direct authorization mismatch'
    );
    require(
      address(CrossChainWrapper(payable(a.crossChainWrapper)).ASSET_SUPPORT()) == a.assetSupportRegistry,
      'cross asset support mismatch'
    );
    require(
      address(SameChainWrapper(payable(a.sameChainWrapper)).ASSET_SUPPORT()) == a.assetSupportRegistry,
      'same asset support mismatch'
    );
    require(CrossChainWrapper(payable(a.crossChainWrapper)).HTLC_IMPLEMENTATION() == a.swapHTLC, 'cross HTLC mismatch');
    require(SameChainWrapper(payable(a.sameChainWrapper)).HTLC_IMPLEMENTATION() == a.swapHTLC, 'same HTLC mismatch');
  }

  function _print(Addresses memory a, address deployer, address owner, address verifier) internal view {
    console.log('Protocol version:', PrototypeDeployment.VERSION);
    console.log('Chain ID:', block.chainid);
    console.log('Deployer:', deployer);
    console.log('Owner:', owner);
    console.log('Trusted verifier:', verifier);
    console.log('AssetSupportRegistry:', a.assetSupportRegistry);
    console.log('DirectAuthorization:', a.directAuthorization);
    console.log('CrossChainWrapper:', a.crossChainWrapper);
    console.log('SameChainWrapper:', a.sameChainWrapper);
    console.log('SwapHTLC:', a.swapHTLC);
  }
}
