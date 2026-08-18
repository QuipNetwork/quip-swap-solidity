// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {DeployProtocol} from '../../script/DeployProtocol.s.sol';
import {ICreateX} from '../../script/ICreateX.sol';
import {PrototypeDeployment} from '../../script/PrototypeDeployment.sol';
import {AssetSupportRegistry} from '../../src/assets/AssetSupportRegistry.sol';
import {DirectAuthorization} from '../../src/authorization/direct/DirectAuthorization.sol';
import {CrossChainWrapper} from '../../src/protocol/CrossChainWrapper.sol';
import {SameChainWrapper} from '../../src/protocol/SameChainWrapper.sol';
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
    assertTrue(a.assetSupportRegistry != a.directAuthorization);
    assertTrue(a.directAuthorization != a.crossChainWrapper);
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
    assertEq(a.assetSupportRegistry, 0x504BA325b5e51a95b0D2225ea7feBE87120c049D);
    assertEq(a.directAuthorization, 0x502d3c6e1790D8cEf8344b9964ea03D08dEB27dA);
    assertEq(a.directAuthorization, 0x502d3c6e1790D8cEf8344b9964ea03D08dEB27dA);
    assertEq(a.crossChainWrapper, 0xBefC4530880E8318250592F76C63007A04b04175);
    assertEq(a.sameChainWrapper, 0x5aa0Ef5b07cdc3FA4c7587e220AB4880df066387);
  }

  function test_localCreate3DeploymentPinsCompleteGraph() public {
    DeployProtocol.Addresses memory a = script.predicted(address(factory), address(this));
    _deploy(
      PrototypeDeployment.Component.AssetSupportRegistry,
      abi.encodePacked(type(AssetSupportRegistry).creationCode, abi.encode(address(this))),
      a.assetSupportRegistry
    );
    _deploy(
      PrototypeDeployment.Component.DirectAuthorization,
      abi.encodePacked(type(DirectAuthorization).creationCode, abi.encode(address(verifier))),
      a.directAuthorization
    );
    _deploy(
      PrototypeDeployment.Component.CrossChainWrapper,
      abi.encodePacked(type(CrossChainWrapper).creationCode, abi.encode(a.directAuthorization, a.assetSupportRegistry)),
      a.crossChainWrapper
    );
    _deploy(
      PrototypeDeployment.Component.SameChainWrapper,
      abi.encodePacked(type(SameChainWrapper).creationCode, abi.encode(a.directAuthorization, a.assetSupportRegistry)),
      a.sameChainWrapper
    );

    assertEq(AssetSupportRegistry(a.assetSupportRegistry).owner(), address(this));
    assertEq(DirectAuthorization(a.directAuthorization).TRUSTED_VERIFIER(), address(verifier));
    assertEq(CrossChainWrapper(payable(a.crossChainWrapper)).DIRECT_AUTHORIZATION(), a.directAuthorization);
    assertEq(address(CrossChainWrapper(payable(a.crossChainWrapper)).ASSET_SUPPORT()), a.assetSupportRegistry);
    assertEq(SameChainWrapper(payable(a.sameChainWrapper)).DIRECT_AUTHORIZATION(), a.directAuthorization);
  }

  function _deploy(PrototypeDeployment.Component component, bytes memory initCode, address expected) internal {
    address deployed =
      ICreateX(address(factory)).deployCreate3(PrototypeDeployment.salt(address(this), component), initCode);
    assertEq(deployed, expected);
    assertGt(deployed.code.length, 0);
  }
}
