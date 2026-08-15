// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetSupportRegistry} from '../src/AssetSupportRegistry.sol';
import {CrossChainWrapper} from '../src/CrossChainWrapper.sol';
import {PQAuthorizationGateway} from '../src/PQAuthorizationGateway.sol';
import {PQIdentityRegistry} from '../src/PQIdentityRegistry.sol';
import {ProtocolHashing} from '../src/ProtocolHashing.sol';
import {TimingPolicy, WrapperMode} from '../src/ProtocolTypes.sol';
import {PrototypeTimingPolicies} from '../src/PrototypeTimingPolicies.sol';
import {SameChainWrapper} from '../src/SameChainWrapper.sol';
import {TimingPolicyRegistry} from '../src/TimingPolicyRegistry.sol';
import {Constants} from './Constants.sol';
import {ICreateX} from './ICreateX.sol';
import {PrototypeDeployment} from './PrototypeDeployment.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';

/// @notice Deploys one complete v1.1 prototype stack through canonical CreateX.
contract DeployProtocol is Script {
  struct Addresses {
    address assetSupportRegistry;
    address timingPolicyRegistry;
    address identityRegistry;
    address authorizationGateway;
    address crossChainWrapper;
    address sameChainWrapper;
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
    require(Constants.CREATEX.code.length != 0, 'CreateX not deployed');
    require(verifier.code.length != 0, 'TRUSTED_VERIFIER not deployed');

    addresses = predicted(Constants.CREATEX, deployer);
    vm.startBroadcast(privateKey);
    _deploy(
      Constants.CREATEX,
      deployer,
      PrototypeDeployment.Component.AssetSupportRegistry,
      abi.encodePacked(type(AssetSupportRegistry).creationCode, abi.encode(owner)),
      addresses.assetSupportRegistry
    );
    _deploy(
      Constants.CREATEX,
      deployer,
      PrototypeDeployment.Component.TimingPolicyRegistry,
      abi.encodePacked(type(TimingPolicyRegistry).creationCode, abi.encode(owner)),
      addresses.timingPolicyRegistry
    );
    _deploy(
      Constants.CREATEX,
      deployer,
      PrototypeDeployment.Component.IdentityRegistry,
      abi.encodePacked(type(PQIdentityRegistry).creationCode, abi.encode(verifier)),
      addresses.identityRegistry
    );
    _deploy(
      Constants.CREATEX,
      deployer,
      PrototypeDeployment.Component.AuthorizationGateway,
      abi.encodePacked(type(PQAuthorizationGateway).creationCode, abi.encode(addresses.identityRegistry)),
      addresses.authorizationGateway
    );
    _deploy(
      Constants.CREATEX,
      deployer,
      PrototypeDeployment.Component.CrossChainWrapper,
      abi.encodePacked(
        type(CrossChainWrapper).creationCode,
        abi.encode(addresses.authorizationGateway, addresses.timingPolicyRegistry, addresses.assetSupportRegistry)
      ),
      addresses.crossChainWrapper
    );
    _deploy(
      Constants.CREATEX,
      deployer,
      PrototypeDeployment.Component.SameChainWrapper,
      abi.encodePacked(
        type(SameChainWrapper).creationCode,
        abi.encode(addresses.authorizationGateway, addresses.timingPolicyRegistry, addresses.assetSupportRegistry)
      ),
      addresses.sameChainWrapper
    );
    _registerPolicies(TimingPolicyRegistry(addresses.timingPolicyRegistry));
    vm.stopBroadcast();

    _verify(addresses, owner, verifier);
    emit ProtocolDeployment(block.chainid, PrototypeDeployment.VERSION, deployer, owner, verifier, addresses);
    _print(addresses, deployer, owner, verifier);
  }

  function predicted(address factory, address deployer) public pure returns (Addresses memory addresses) {
    addresses.assetSupportRegistry =
      PrototypeDeployment.predict(factory, deployer, PrototypeDeployment.Component.AssetSupportRegistry);
    addresses.timingPolicyRegistry =
      PrototypeDeployment.predict(factory, deployer, PrototypeDeployment.Component.TimingPolicyRegistry);
    addresses.identityRegistry =
      PrototypeDeployment.predict(factory, deployer, PrototypeDeployment.Component.IdentityRegistry);
    addresses.authorizationGateway =
      PrototypeDeployment.predict(factory, deployer, PrototypeDeployment.Component.AuthorizationGateway);
    addresses.crossChainWrapper =
      PrototypeDeployment.predict(factory, deployer, PrototypeDeployment.Component.CrossChainWrapper);
    addresses.sameChainWrapper =
      PrototypeDeployment.predict(factory, deployer, PrototypeDeployment.Component.SameChainWrapper);
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

  function _registerPolicies(TimingPolicyRegistry registry) internal {
    TimingPolicy memory baseToOp = PrototypeTimingPolicies.baseSepoliaToOpSepolia();
    TimingPolicy memory opToBase = PrototypeTimingPolicies.opSepoliaToBaseSepolia();
    bytes32 baseToOpId = PrototypeTimingPolicies.policyId(baseToOp);
    bytes32 opToBaseId = PrototypeTimingPolicies.policyId(opToBase);
    if (!registry.isRegistered(baseToOpId)) registry.registerPolicy(baseToOpId, baseToOp);
    if (!registry.isRegistered(opToBaseId)) registry.registerPolicy(opToBaseId, opToBase);
    TimingPolicy memory local = TimingPolicy({
      policyVersion: 1,
      mode: WrapperMode.SameChain,
      partyChainId: block.chainid,
      counterpartyChainId: block.chainid,
      partyToCounterpartyDelay: 0,
      counterpartyToPartyDelay: 0
    });
    bytes32 localId = ProtocolHashing.timingPolicyId(local);
    if (!registry.isRegistered(localId)) registry.registerPolicy(localId, local);
  }

  function _verify(Addresses memory a, address owner, address verifier) internal view {
    require(AssetSupportRegistry(a.assetSupportRegistry).owner() == owner, 'asset owner mismatch');
    require(TimingPolicyRegistry(a.timingPolicyRegistry).owner() == owner, 'policy owner mismatch');
    require(PQIdentityRegistry(a.identityRegistry).TRUSTED_VERIFIER() == verifier, 'verifier mismatch');
    require(
      address(PQAuthorizationGateway(a.authorizationGateway).REGISTRY()) == a.identityRegistry, 'registry mismatch'
    );
    require(
      CrossChainWrapper(payable(a.crossChainWrapper)).DIRECT_GATEWAY() == a.authorizationGateway,
      'cross gateway mismatch'
    );
    require(
      SameChainWrapper(payable(a.sameChainWrapper)).DIRECT_GATEWAY() == a.authorizationGateway, 'same gateway mismatch'
    );
  }

  function _print(Addresses memory a, address deployer, address owner, address verifier) internal view {
    console.log('Protocol version:', PrototypeDeployment.VERSION);
    console.log('Chain ID:', block.chainid);
    console.log('Deployer:', deployer);
    console.log('Owner:', owner);
    console.log('Trusted verifier:', verifier);
    console.log('AssetSupportRegistry:', a.assetSupportRegistry);
    console.log('TimingPolicyRegistry:', a.timingPolicyRegistry);
    console.log('PQIdentityRegistry:', a.identityRegistry);
    console.log('PQAuthorizationGateway:', a.authorizationGateway);
    console.log('CrossChainWrapper:', a.crossChainWrapper);
    console.log('SameChainWrapper:', a.sameChainWrapper);
    console.logBytes32(PrototypeTimingPolicies.policyId(PrototypeTimingPolicies.baseSepoliaToOpSepolia()));
    console.logBytes32(PrototypeTimingPolicies.policyId(PrototypeTimingPolicies.opSepoliaToBaseSepolia()));
  }
}
