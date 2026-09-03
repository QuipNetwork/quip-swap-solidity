// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {DeployProtocol} from '../../script/DeployProtocol.s.sol';
import {ICreateX} from '../../script/ICreateX.sol';
import {PrototypeDeployment} from '../../script/PrototypeDeployment.sol';
import {AssetSupportRegistry} from '../../src/assets/AssetSupportRegistry.sol';
import {DirectAuthorization} from '../../src/authorization/direct/DirectAuthorization.sol';
import {CrossChainWrapper} from '../../src/protocol/CrossChainWrapper.sol';
import {SameChainWrapper} from '../../src/protocol/SameChainWrapper.sol';
import {SwapHTLC} from '../../src/protocol/SwapHTLC.sol';
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
    assertTrue(a.sameChainWrapper != a.swapHTLC);
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
    assertEq(a.assetSupportRegistry, 0x9Ba57720D36d83954e5ba03185e92A918D028EDF);
    assertEq(a.directAuthorization, 0xe5c123bbB955e82208d76114aBe4170C0E0b2F95);
    assertEq(a.crossChainWrapper, 0x795C93561Bd9F9E30FF62aCDe821B38148229E30);
    assertEq(a.sameChainWrapper, 0xE740Bf2De5123F801AdCf534414F039ca2e83c44);
    assertEq(a.swapHTLC, 0x1268B3FF8C710ca5629Bb0385d84D130A8e139f9);
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
    _deploy(PrototypeDeployment.Component.SwapHTLC, type(SwapHTLC).creationCode, a.swapHTLC);
    _deploy(
      PrototypeDeployment.Component.CrossChainWrapper,
      abi.encodePacked(
        type(CrossChainWrapper).creationCode,
        abi.encode(a.directAuthorization, a.assetSupportRegistry, a.swapHTLC, address(this))
      ),
      a.crossChainWrapper
    );
    _deploy(
      PrototypeDeployment.Component.SameChainWrapper,
      abi.encodePacked(
        type(SameChainWrapper).creationCode,
        abi.encode(a.directAuthorization, a.assetSupportRegistry, a.swapHTLC, address(this))
      ),
      a.sameChainWrapper
    );

    assertEq(AssetSupportRegistry(a.assetSupportRegistry).owner(), address(this));
    assertEq(CrossChainWrapper(payable(a.crossChainWrapper)).owner(), address(this));
    assertEq(SameChainWrapper(payable(a.sameChainWrapper)).owner(), address(this));
    assertEq(DirectAuthorization(a.directAuthorization).TRUSTED_VERIFIER(), address(verifier));
    assertEq(CrossChainWrapper(payable(a.crossChainWrapper)).DIRECT_AUTHORIZATION(), a.directAuthorization);
    assertEq(address(CrossChainWrapper(payable(a.crossChainWrapper)).ASSET_SUPPORT()), a.assetSupportRegistry);
    assertEq(SameChainWrapper(payable(a.sameChainWrapper)).DIRECT_AUTHORIZATION(), a.directAuthorization);
    assertEq(address(SameChainWrapper(payable(a.sameChainWrapper)).ASSET_SUPPORT()), a.assetSupportRegistry);
    assertEq(CrossChainWrapper(payable(a.crossChainWrapper)).HTLC_IMPLEMENTATION(), a.swapHTLC);
    assertEq(SameChainWrapper(payable(a.sameChainWrapper)).HTLC_IMPLEMENTATION(), a.swapHTLC);
  }

  function _deploy(PrototypeDeployment.Component component, bytes memory initCode, address expected) internal {
    address deployed =
      ICreateX(address(factory)).deployCreate3(PrototypeDeployment.salt(address(this), component), initCode);
    assertEq(deployed, expected);
    assertGt(deployed.code.length, 0);
  }
}
