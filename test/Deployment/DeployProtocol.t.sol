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
    assertTrue(a.assetSupportRegistry != a.identityRegistry);
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
    assertEq(a.assetSupportRegistry, 0x87809f19A53302A03380189146c1291F5f4baDe9);
    assertEq(a.identityRegistry, 0xeEe2445807eC6eCe54EA5614C9eedeE1CD5f3c58);
    assertEq(a.authorizationGateway, 0xeEFC2Fc5Bd8F22D865Bd5956C058301e1DC04E29);
    assertEq(a.crossChainWrapper, 0xb25ABE97C7ff0Dd32F798f2f41b65418ad2D73Ef);
    assertEq(a.sameChainWrapper, 0x9236D569776AAD47d661E57D5a490bEbC3798145);
  }

  function test_localCreate3DeploymentPinsCompleteGraph() public {
    DeployProtocol.Addresses memory a = script.predicted(address(factory), address(this));
    _deploy(
      PrototypeDeployment.Component.AssetSupportRegistry,
      abi.encodePacked(type(AssetSupportRegistry).creationCode, abi.encode(address(this))),
      a.assetSupportRegistry
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
        type(CrossChainWrapper).creationCode, abi.encode(a.authorizationGateway, a.assetSupportRegistry)
      ),
      a.crossChainWrapper
    );
    _deploy(
      PrototypeDeployment.Component.SameChainWrapper,
      abi.encodePacked(type(SameChainWrapper).creationCode, abi.encode(a.authorizationGateway, a.assetSupportRegistry)),
      a.sameChainWrapper
    );

    assertEq(AssetSupportRegistry(a.assetSupportRegistry).owner(), address(this));
    assertEq(PQIdentityRegistry(a.identityRegistry).TRUSTED_VERIFIER(), address(verifier));
    assertEq(address(PQAuthorizationGateway(a.authorizationGateway).REGISTRY()), a.identityRegistry);
    assertEq(CrossChainWrapper(payable(a.crossChainWrapper)).DIRECT_GATEWAY(), a.authorizationGateway);
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
