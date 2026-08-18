// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {DeployProtocol} from '../../script/DeployProtocol.s.sol';
import {ICreateX} from '../../script/ICreateX.sol';
import {PrototypeDeployment} from '../../script/PrototypeDeployment.sol';
import {PQAuthorizationGateway} from '../../src/authorization/PQAuthorizationGateway.sol';
import {PQIdentityRegistry} from '../../src/authorization/PQIdentityRegistry.sol';
import {CrossChainWrapper} from '../../src/protocol/CrossChainWrapper.sol';
import {SameChainWrapper} from '../../src/protocol/SameChainWrapper.sol';
import {AssetSupportRegistry} from '../../src/registry/AssetSupportRegistry.sol';
import {TimingPolicyRegistry} from '../../src/registry/TimingPolicyRegistry.sol';
import {CreateXMock} from '../mocks/CreateXMock.sol';
import {KeyBoundVerifierMock} from '../mocks/KeyBoundVerifierMock.sol';
import {Test} from 'forge-std-1.14.0/Test.sol';

contract DeployProtocolTest is Test {
  address internal constant CANONICAL_CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
  address internal constant VECTOR_DEPLOYER = 0x1111111111111111111111111111111111111111;
  CreateXMock internal factory;
  KeyBoundVerifierMock internal verifier;
  DeployProtocol internal script;

  function setUp() public {
    factory = new CreateXMock();
    verifier = new KeyBoundVerifierMock();
    script = new DeployProtocol();
  }

  function test_componentSaltsAndAddressesAreDistinctAndConstructorIndependent() public view {
    DeployProtocol.Addresses memory a = script.predicted(address(factory), address(this));
    assertTrue(a.assetSupportRegistry != a.timingPolicyRegistry);
    assertTrue(a.timingPolicyRegistry != a.identityRegistry);
    assertTrue(a.identityRegistry != a.authorizationGateway);
    assertTrue(a.authorizationGateway != a.crossChainWrapper);
    assertTrue(a.crossChainWrapper != a.sameChainWrapper);
    assertEq(
      a.crossChainWrapper,
      PrototypeDeployment.predict(address(factory), address(this), PrototypeDeployment.Component.CrossChainWrapper)
    );
  }

  function test_predictionsAreChainIndependent() public {
    DeployProtocol.Addresses memory first = script.predicted(address(factory), address(this));
    vm.chainId(31_338);
    DeployProtocol.Addresses memory second = script.predicted(address(factory), address(this));
    assertEq(keccak256(abi.encode(first)), keccak256(abi.encode(second)));
  }

  function test_predictionMatchesPublishedSdkVector() public view {
    DeployProtocol.Addresses memory a = script.predicted(CANONICAL_CREATEX, VECTOR_DEPLOYER);
    assertEq(a.assetSupportRegistry, 0x999Cbf13223e2421fAb3d16894a19E6A1DfEE12E);
    assertEq(a.timingPolicyRegistry, 0x216B1ffa9B0b9b0075d3F452bA54418F3c7BFc6f);
    assertEq(a.identityRegistry, 0x617f50EfC9D607d758F14221ce8f5757927A1F15);
    assertEq(a.authorizationGateway, 0x132A36eDe5F30C9D00477d9c8181A3E8e1Ef356F);
    assertEq(a.crossChainWrapper, 0x67F0DB16f0a61852a63c8c1771EB5440E89396D4);
    assertEq(a.sameChainWrapper, 0x877ED96E48852fB3640c67e576B4ceC3C1C026A0);
  }

  function test_localCreate3DeploymentPinsCompleteGraph() public {
    DeployProtocol.Addresses memory a = script.predicted(address(factory), address(this));
    _deploy(
      PrototypeDeployment.Component.AssetSupportRegistry,
      abi.encodePacked(type(AssetSupportRegistry).creationCode, abi.encode(address(this))),
      a.assetSupportRegistry
    );
    _deploy(
      PrototypeDeployment.Component.TimingPolicyRegistry,
      abi.encodePacked(type(TimingPolicyRegistry).creationCode, abi.encode(address(this))),
      a.timingPolicyRegistry
    );
    _deploy(
      PrototypeDeployment.Component.IdentityRegistry,
      abi.encodePacked(type(PQIdentityRegistry).creationCode, abi.encode(address(verifier))),
      a.identityRegistry
    );
    _deploy(
      PrototypeDeployment.Component.AuthorizationGateway,
      abi.encodePacked(type(PQAuthorizationGateway).creationCode, abi.encode(a.identityRegistry)),
      a.authorizationGateway
    );
    _deploy(
      PrototypeDeployment.Component.CrossChainWrapper,
      abi.encodePacked(
        type(CrossChainWrapper).creationCode,
        abi.encode(a.authorizationGateway, a.timingPolicyRegistry, a.assetSupportRegistry)
      ),
      a.crossChainWrapper
    );
    _deploy(
      PrototypeDeployment.Component.SameChainWrapper,
      abi.encodePacked(
        type(SameChainWrapper).creationCode,
        abi.encode(a.authorizationGateway, a.timingPolicyRegistry, a.assetSupportRegistry)
      ),
      a.sameChainWrapper
    );

    assertEq(AssetSupportRegistry(a.assetSupportRegistry).owner(), address(this));
    assertEq(TimingPolicyRegistry(a.timingPolicyRegistry).owner(), address(this));
    assertEq(PQIdentityRegistry(a.identityRegistry).TRUSTED_VERIFIER(), address(verifier));
    assertEq(address(PQAuthorizationGateway(a.authorizationGateway).REGISTRY()), a.identityRegistry);
    assertEq(CrossChainWrapper(payable(a.crossChainWrapper)).DIRECT_GATEWAY(), a.authorizationGateway);
    assertEq(address(CrossChainWrapper(payable(a.crossChainWrapper)).TIMING_POLICIES()), a.timingPolicyRegistry);
    assertEq(address(CrossChainWrapper(payable(a.crossChainWrapper)).ASSET_SUPPORT()), a.assetSupportRegistry);
    assertEq(SameChainWrapper(payable(a.sameChainWrapper)).DIRECT_GATEWAY(), a.authorizationGateway);
  }

  function _deploy(PrototypeDeployment.Component component, bytes memory initCode, address expected) internal {
    address deployed =
      ICreateX(address(factory)).deployCreate3(PrototypeDeployment.salt(address(this), component), initCode);
    assertEq(deployed, expected);
    assertGt(deployed.code.length, 0);
  }
}
