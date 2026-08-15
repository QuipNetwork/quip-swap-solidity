// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetCustody} from '../../src/AssetCustody.sol';
import {AssetSupport} from '../../src/AssetSupport.sol';
import {AssetSupportRegistry} from '../../src/AssetSupportRegistry.sol';
import {CrossChainStateMachine} from '../../src/CrossChainStateMachine.sol';
import {CrossChainWrapper} from '../../src/CrossChainWrapper.sol';
import {PQAuthorizationGateway} from '../../src/PQAuthorizationGateway.sol';
import {PQIdentityRegistry} from '../../src/PQIdentityRegistry.sol';
import {ProtocolHashing} from '../../src/ProtocolHashing.sol';
import {
  AuthorizationMode,
  CommitAuthorizationRequest,
  CrossChainLegState,
  DelegationPolicy,
  InitialRegistration,
  KeyRole,
  ProtocolTerms,
  SameChainState,
  SideTerms,
  TimingPolicy,
  WrapperMode
} from '../../src/ProtocolTypes.sol';
import {QuipWallet} from '../../src/QuipWallet.sol';
import {SameChainStateMachine} from '../../src/SameChainStateMachine.sol';
import {SameChainWrapper} from '../../src/SameChainWrapper.sol';
import {Asset, AssetType} from '../../src/TermsLib.sol';
import {TimingPolicyRegistry} from '../../src/TimingPolicyRegistry.sol';
import {ITimingPolicyRegistry} from '../../src/interfaces/ITimingPolicyRegistry.sol';
import {ReentrantRecipient} from '../attack/Reentrancy.t.sol';
import {RegisteredCommitTargetHarness} from '../harness/RegisteredCommitTargetHarness.sol';
import {ERC1155Mock} from '../mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';
import {FeeOnTransferERC20Mock} from '../mocks/FeeOnTransferERC20Mock.sol';
import {KeyBoundVerifierMock} from '../mocks/KeyBoundVerifierMock.sol';
import {MaliciousERC20Mock} from '../mocks/MaliciousERC20Mock.sol';
import {MaliciousERC721Mock} from '../mocks/MaliciousERC721Mock.sol';
import {Test} from 'forge-std-1.14.0/Test.sol';

contract WrapperFundingTest is Test {
  uint256 internal constant ALICE_PRIVATE = 0xA11CE;
  uint256 internal constant BOB_PRIVATE = 0xB0B;
  uint256 internal constant BROKER_PRIVATE = 0xB20;
  bytes32 internal constant SECRET = keccak256('settlement-secret');
  bytes32 internal constant BOB_COMMIT_SECRET = keccak256('bob-commit-secret');
  address internal constant RECIPIENT = address(0xCAFE);
  address internal constant RECLAIMER = address(0xD00D);
  address internal constant RELAYER = address(0x7E1A);

  address internal alice;
  address internal bob;
  address internal broker;
  bytes internal aliceKey;
  bytes internal bobKey;
  bytes internal brokerKey;
  bytes internal walletKey;

  KeyBoundVerifierMock internal verifier;
  PQIdentityRegistry internal registry;
  PQAuthorizationGateway internal gateway;
  TimingPolicyRegistry internal policies;
  AssetSupportRegistry internal assetSupport;
  CrossChainWrapper internal cross;
  SameChainWrapper internal same;
  QuipWallet internal wallet;
  RegisteredCommitTargetHarness internal registrationTarget;
  ERC20Mock internal token;

  function setUp() public {
    vm.warp(100);
    alice = vm.addr(ALICE_PRIVATE);
    bob = vm.addr(BOB_PRIVATE);
    broker = vm.addr(BROKER_PRIVATE);
    verifier = new KeyBoundVerifierMock();
    registry = new PQIdentityRegistry();
    registrationTarget = new RegisteredCommitTargetHarness();
    aliceKey = _key('alice');
    bobKey = _key('bob');
    brokerKey = _key('broker');
    walletKey = _key('wallet');
    _register(alice, aliceKey);
    _register(bob, bobKey);
    _register(broker, brokerKey);
    gateway = new PQAuthorizationGateway(registry);
    policies = new TimingPolicyRegistry(address(this));
    assetSupport = new AssetSupportRegistry(address(this));
    cross = new CrossChainWrapper(address(gateway), policies, assetSupport);
    same = new SameChainWrapper(address(gateway), policies, assetSupport);
    wallet = new QuipWallet(address(this), registry, walletKey);
    token = new ERC20Mock('Token', 'TOK', 18);
  }

  function test_directBrokerTransportsButPrincipalFundsERC20() public {
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(token), 0, 10 ether);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 1);
    terms.partySide.delegationPolicy = DelegationPolicy.SpecificDelegate;
    terms.partySide.delegate = broker;
    terms.partySide.delegateKeyVersion = 1;
    _rebindCross(terms);
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    token.mint(alice, 10 ether);
    vm.prank(alice);
    token.approve(address(cross), 10 ether);

    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 1);
    vm.prank(broker);
    gateway.authorizeCommit(request, _signature(request, address(gateway), aliceKey));

    assertEq(token.balanceOf(address(cross)), 10 ether);
    assertEq(token.balanceOf(broker), 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
  }

  function test_brokerApprovalCannotReplacePrincipalApproval() public {
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(token), 0, 10 ether);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 2);
    terms.partySide.delegationPolicy = DelegationPolicy.SpecificDelegate;
    terms.partySide.delegate = broker;
    terms.partySide.delegateKeyVersion = 1;
    _rebindCross(terms);
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    token.mint(broker, 10 ether);
    vm.prank(broker);
    token.approve(address(cross), 10 ether);
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 2);

    vm.expectRevert();
    vm.prank(broker);
    gateway.authorizeCommit(request, _signature(request, address(gateway), aliceKey));
    assertEq(token.balanceOf(broker), 10 ether);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));
  }

  function test_failedRegisterAndCommitRollsBackIdentityCustodyStateAndAuthorizationNonce() public {
    address newcomer = vm.addr(0xCA11);
    bytes memory newcomerKey = _key('newcomer');
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(token), 0, 10 ether);
    (ProtocolTerms memory terms, bytes32 lock) =
      _crossTerms(newcomer, AuthorizationMode.RegisteredDirect, 1, assets, 77);
    CommitAuthorizationRequest memory commitRequest = _request(address(cross), terms, true, lock, 77);
    bytes32 payloadHash = ProtocolHashing.commitPayloadHash(
      terms,
      true,
      address(gateway),
      address(cross),
      lock,
      ProtocolHashing.expectedSourceState(true, WrapperMode.CrossChain),
      commitRequest.actionNonce,
      commitRequest.expiry
    );
    bytes memory commitSignature = _pqSig(newcomerKey, payloadHash);
    InitialRegistration memory registration = InitialRegistration({
      eoa: newcomer,
      activePQKey: newcomerKey,
      recoveryPQKey: _key('newcomer-recovery'),
      commitTarget: address(gateway),
      commitPayloadHash: payloadHash,
      operationNonce: keccak256('newcomer-registration'),
      expiry: 190
    });
    bytes32 registrationDigest = registry.registrationDigest(registration);
    bytes memory activeProof = _pqSig(
      newcomerKey,
      keccak256(
        abi.encode(
          'InterlockKeyPossession-v1.1', registrationDigest, KeyRole.Active, keccak256(registration.activePQKey)
        )
      )
    );
    bytes memory recoveryProof = _pqSig(
      registration.recoveryPQKey,
      keccak256(
        abi.encode(
          'InterlockKeyPossession-v1.1', registrationDigest, KeyRole.Recovery, keccak256(registration.recoveryPQKey)
        )
      )
    );
    bytes memory commitData = abi.encode(commitRequest, commitSignature);
    token.mint(newcomer, 10 ether);

    vm.expectRevert(PQIdentityRegistry.CommitCallbackFailed.selector);
    vm.prank(newcomer);
    registry.registerAndCommit(registration, '', activeProof, recoveryProof, commitData);
    assertEq(registry.identityOf(newcomer).activeKeyVersion, 0);
    assertEq(token.balanceOf(newcomer), 10 ether);
    assertEq(token.balanceOf(address(cross)), 0);
    assertEq(cross.reserved(assets[0]), 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));

    vm.prank(newcomer);
    token.approve(address(cross), 10 ether);
    vm.prank(newcomer);
    registry.registerAndCommit(registration, '', activeProof, recoveryProof, commitData);
    assertEq(registry.identityOf(newcomer).activeKeyVersion, 1);
    assertEq(token.balanceOf(newcomer), 0);
    assertEq(token.balanceOf(address(cross)), 10 ether);
    assertEq(cross.reserved(assets[0]), 10 ether);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
  }

  function test_walletPrincipalFundsTokenWhileRelayerOnlyTransports() public {
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(token), 0, 10 ether);
    (ProtocolTerms memory terms, bytes32 lock) =
      _crossTerms(address(wallet), AuthorizationMode.QuipWallet, 0, assets, 3);
    terms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    _rebindCross(terms);
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    token.mint(address(wallet), 10 ether);
    wallet.execute(address(token), 0, abi.encodeCall(token.approve, (address(cross), 10 ether)));
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 3);

    vm.prank(RELAYER);
    wallet.authorizeCommit(request, _signature(request, address(wallet), walletKey));

    assertEq(token.balanceOf(address(cross)), 10 ether);
    assertEq(token.balanceOf(RELAYER), 0);
  }

  function test_nativeValueMayBeTransportedButMustMatchSignedAssetsExactly() public {
    Asset[] memory assets = _oneAsset(AssetType.Native, address(0), 0, 1 ether);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 4);
    terms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    _rebindCross(terms);
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 4);
    bytes memory signature = _signature(request, address(gateway), aliceKey);
    vm.deal(RELAYER, 2 ether);

    vm.expectRevert(AssetCustody.IncorrectNativeAmount.selector);
    vm.prank(RELAYER);
    gateway.authorizeCommit{value: 2 ether}(request, signature);
    vm.prank(RELAYER);
    gateway.authorizeCommit{value: 1 ether}(request, signature);

    assertEq(address(cross).balance, 1 ether);
    assertEq(RELAYER.balance, 1 ether);
  }

  function test_directPrincipalFundsERC721AndERC1155() public {
    ERC721Mock nft = new ERC721Mock('NFT', 'NFT');
    ERC1155Mock multi = new ERC1155Mock('');
    Asset[] memory assets = new Asset[](2);
    assets[0] = Asset({assetType: AssetType.ERC721, target: address(nft), id: 7, amount: 1});
    assets[1] = Asset({assetType: AssetType.ERC1155, target: address(multi), id: 9, amount: 3});
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 5);
    nft.mint(alice, 7);
    multi.mint(alice, 9, 3, '');
    vm.startPrank(alice);
    nft.approve(address(cross), 7);
    multi.setApprovalForAll(address(cross), true);
    vm.stopPrank();
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 5);

    vm.prank(alice);
    gateway.authorizeCommit(request, _signature(request, address(gateway), aliceKey));

    assertEq(nft.ownerOf(7), address(cross));
    assertEq(multi.balanceOf(address(cross), 9), 3);
  }

  function test_feeOnTransferAssetIsRejectedAtomically() public {
    FeeOnTransferERC20Mock feeToken = new FeeOnTransferERC20Mock('Fee', 'FEE', 100);
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(feeToken), 0, 10 ether);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 6);
    feeToken.mint(alice, 10 ether);
    vm.prank(alice);
    feeToken.approve(address(cross), 10 ether);
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 6);

    vm.expectRevert(AssetCustody.UnexpectedAmountReceived.selector);
    vm.prank(alice);
    gateway.authorizeCommit(request, _signature(request, address(gateway), aliceKey));
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));
  }

  function test_unapprovedAssetIsRejectedBeforeCustodyAndCanBeEnabled() public {
    ERC20Mock unsupported = new ERC20Mock('Unsupported', 'NO', 18);
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(unsupported), 0, 10 ether);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 67);
    assetSupport.setAssetSupport(AssetType.ERC20, address(unsupported), false);
    unsupported.mint(alice, 10 ether);
    vm.prank(alice);
    unsupported.approve(address(cross), 10 ether);
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 67);
    bytes memory signature = _signature(request, address(gateway), aliceKey);

    vm.expectRevert(
      abi.encodeWithSelector(AssetSupport.UnsupportedAsset.selector, AssetType.ERC20, address(unsupported))
    );
    vm.prank(alice);
    gateway.authorizeCommit(request, signature);
    assertEq(unsupported.balanceOf(alice), 10 ether);
    assertEq(unsupported.balanceOf(address(cross)), 0);
    assertEq(cross.reserved(assets[0]), 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));

    assetSupport.setAssetSupport(AssetType.ERC20, address(unsupported), true);
    vm.prank(alice);
    gateway.authorizeCommit(request, signature);
    assertEq(unsupported.balanceOf(address(cross)), 10 ether);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
  }

  function test_assetSupportIsTypeScopedAndDelistingDoesNotStrandEscrow() public {
    ERC721Mock nft = new ERC721Mock('Scoped', 'SCOPE');
    Asset[] memory assets = _oneAsset(AssetType.ERC721, address(nft), 12, 1);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 68);
    assetSupport.setAssetSupport(AssetType.ERC721, address(nft), false);
    assetSupport.setAssetSupport(AssetType.ERC20, address(nft), true);
    nft.mint(alice, 12);
    vm.prank(alice);
    nft.approve(address(cross), 12);
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 68);
    bytes memory signature = _signature(request, address(gateway), aliceKey);

    vm.expectRevert(abi.encodeWithSelector(AssetSupport.UnsupportedAsset.selector, AssetType.ERC721, address(nft)));
    vm.prank(alice);
    gateway.authorizeCommit(request, signature);

    assetSupport.setAssetSupport(AssetType.ERC721, address(nft), true);
    vm.prank(alice);
    gateway.authorizeCommit(request, signature);
    assetSupport.setAssetSupport(AssetType.ERC721, address(nft), false);
    cross.claim(terms, true, lock, SECRET);

    assertEq(nft.ownerOf(12), RECIPIENT);
    assertEq(cross.reserved(assets[0]), 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_maliciousIncomingERC20BehaviorsRevertAtomicallyAndPermitRetry() public {
    for (uint8 raw = 1; raw <= uint8(MaliciousERC20Mock.Behavior.ReturnFalse); ++raw) {
      MaliciousERC20Mock malicious = new MaliciousERC20Mock();
      Asset[] memory assets = _oneAsset(AssetType.ERC20, address(malicious), 0, 10 ether);
      uint256 nonce = 60 + raw;
      (ProtocolTerms memory terms, bytes32 lock) =
        _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, nonce);
      CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, nonce);
      bytes memory signature = _signature(request, address(gateway), aliceKey);
      malicious.mint(alice, 11 ether);
      vm.prank(alice);
      malicious.approve(address(cross), 10 ether);
      malicious.setBehavior(MaliciousERC20Mock.Behavior(raw));

      vm.expectRevert();
      vm.prank(alice);
      gateway.authorizeCommit(request, signature);
      assertEq(malicious.balanceOf(alice), 11 ether);
      assertEq(malicious.balanceOf(address(cross)), 0);
      assertEq(cross.reserved(assets[0]), 0);
      assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));

      malicious.setBehavior(MaliciousERC20Mock.Behavior.Exact);
      vm.prank(alice);
      gateway.authorizeCommit(request, signature);
      assertEq(malicious.balanceOf(address(cross)), 10 ether);
      assertEq(cross.reserved(assets[0]), 10 ether);
      assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
    }
  }

  function test_maliciousNoOpPayoutRollsBackClaimStateAndReserve() public {
    MaliciousERC20Mock malicious = new MaliciousERC20Mock();
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(malicious), 0, 10 ether);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 70);
    malicious.mint(alice, 10 ether);
    vm.prank(alice);
    malicious.approve(address(cross), 10 ether);
    _directCommit(terms, true, lock, 70, alice, aliceKey, bytes32(0));
    malicious.setBehavior(MaliciousERC20Mock.Behavior.NoOp);

    vm.expectRevert(AssetCustody.UnexpectedAmountReceived.selector);
    cross.claim(terms, true, lock, SECRET);
    assertEq(malicious.balanceOf(RECIPIENT), 0);
    assertEq(malicious.balanceOf(address(cross)), 10 ether);
    assertEq(cross.reserved(assets[0]), 10 ether);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));

    malicious.setBehavior(MaliciousERC20Mock.Behavior.Exact);
    cross.claim(terms, true, lock, SECRET);
    assertEq(malicious.balanceOf(RECIPIENT), 10 ether);
    assertEq(cross.reserved(assets[0]), 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_maliciousNoOpERC721CollectionRollsBackAndPermitsRetry() public {
    MaliciousERC721Mock malicious = new MaliciousERC721Mock();
    Asset[] memory assets = _oneAsset(AssetType.ERC721, address(malicious), 7, 1);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 71);
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 71);
    bytes memory signature = _signature(request, address(gateway), aliceKey);
    malicious.mint(alice, 7);
    vm.prank(alice);
    malicious.approve(address(cross), 7);
    malicious.setBehavior(MaliciousERC721Mock.Behavior.NoOp);

    vm.expectRevert(abi.encodeWithSelector(AssetCustody.UnexpectedERC721Owner.selector, address(cross), alice));
    vm.prank(alice);
    gateway.authorizeCommit(request, signature);
    assertEq(malicious.ownerOf(7), alice);
    assertEq(cross.reserved(assets[0]), 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));

    malicious.setBehavior(MaliciousERC721Mock.Behavior.Exact);
    vm.prank(alice);
    gateway.authorizeCommit(request, signature);
    assertEq(malicious.ownerOf(7), address(cross));
    assertEq(cross.reserved(assets[0]), 1);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
  }

  function test_duplicateERC721ReferencesCannotCreateMultipleReserves() public {
    ERC721Mock nft = new ERC721Mock('NFT', 'NFT');
    Asset[] memory assets = new Asset[](2);
    assets[0] = Asset({assetType: AssetType.ERC721, target: address(nft), id: 11, amount: 1});
    assets[1] = assets[0];
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 76);
    nft.mint(alice, 11);
    vm.prank(alice);
    nft.approve(address(cross), 11);
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 76);

    vm.expectRevert();
    vm.prank(alice);
    gateway.authorizeCommit(request, _signature(request, address(gateway), aliceKey));
    assertEq(nft.ownerOf(11), alice);
    assertEq(cross.reserved(assets[0]), 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));
  }

  function test_maliciousNoOpERC721ClaimRollsBackAndPermitsRetry() public {
    MaliciousERC721Mock malicious = new MaliciousERC721Mock();
    Asset[] memory assets = _oneAsset(AssetType.ERC721, address(malicious), 8, 1);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 72);
    malicious.mint(alice, 8);
    vm.prank(alice);
    malicious.approve(address(cross), 8);
    _directCommit(terms, true, lock, 72, alice, aliceKey, bytes32(0));
    malicious.setBehavior(MaliciousERC721Mock.Behavior.NoOp);

    vm.expectRevert(abi.encodeWithSelector(AssetCustody.UnexpectedERC721Owner.selector, RECIPIENT, address(cross)));
    cross.claim(terms, true, lock, SECRET);
    assertEq(malicious.ownerOf(8), address(cross));
    assertEq(cross.reserved(assets[0]), 1);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));

    malicious.setBehavior(MaliciousERC721Mock.Behavior.Exact);
    cross.claim(terms, true, lock, SECRET);
    assertEq(malicious.ownerOf(8), RECIPIENT);
    assertEq(cross.reserved(assets[0]), 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_maliciousNoOpERC721ReclaimRollsBackAndPermitsRetry() public {
    MaliciousERC721Mock malicious = new MaliciousERC721Mock();
    Asset[] memory assets = _oneAsset(AssetType.ERC721, address(malicious), 9, 1);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 73);
    malicious.mint(alice, 9);
    vm.prank(alice);
    malicious.approve(address(cross), 9);
    _directCommit(terms, true, lock, 73, alice, aliceKey, bytes32(0));
    vm.warp(terms.partySide.reclaimRelease);
    malicious.setBehavior(MaliciousERC721Mock.Behavior.NoOp);

    vm.expectRevert(abi.encodeWithSelector(AssetCustody.UnexpectedERC721Owner.selector, RECLAIMER, address(cross)));
    cross.reclaim(terms, true, lock);
    assertEq(malicious.ownerOf(9), address(cross));
    assertEq(cross.reserved(assets[0]), 1);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));

    malicious.setBehavior(MaliciousERC721Mock.Behavior.Exact);
    cross.reclaim(terms, true, lock);
    assertEq(malicious.ownerOf(9), RECLAIMER);
    assertEq(cross.reserved(assets[0]), 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Reclaimed));
  }

  function test_sameChainSecondERC721PayoutFailureRollsBackBothLegs() public {
    MaliciousERC721Mock malicious = new MaliciousERC721Mock();
    Asset[] memory partyAssets = _oneAsset(AssetType.ERC20, address(token), 0, 10 ether);
    Asset[] memory counterpartyAssets = _oneAsset(AssetType.ERC721, address(malicious), 10, 1);
    ProtocolTerms memory terms;
    terms.partySide = _side(alice, AuthorizationMode.RegisteredDirect, 1, partyAssets, 74);
    terms.counterpartySide = _side(bob, AuthorizationMode.RegisteredDirect, 1, counterpartyAssets, 174);
    TimingPolicy memory policy = TimingPolicy(1, WrapperMode.SameChain, block.chainid, block.chainid, 0, 0);
    terms.timingPolicyId = ProtocolHashing.timingPolicyId(policy);
    policies.registerPolicy(terms.timingPolicyId, policy);
    bytes32 lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    token.mint(alice, 10 ether);
    malicious.mint(bob, 10);
    vm.prank(alice);
    token.approve(address(same), 10 ether);
    vm.prank(bob);
    malicious.approve(address(same), 10);
    _directCommitTo(address(same), terms, true, lock, 74, alice, aliceKey, bytes32(0));
    _directCommitTo(address(same), terms, false, lock, 75, bob, bobKey, bytes32(0));
    malicious.setBehavior(MaliciousERC721Mock.Behavior.NoOp);

    vm.expectRevert(abi.encodeWithSelector(AssetCustody.UnexpectedERC721Owner.selector, RECIPIENT, address(same)));
    same.claim(terms, lock, SECRET);
    assertEq(token.balanceOf(RECIPIENT), 0);
    assertEq(token.balanceOf(address(same)), 10 ether);
    assertEq(malicious.ownerOf(10), address(same));
    assertEq(same.reserved(partyAssets[0]), 10 ether);
    assertEq(same.reserved(counterpartyAssets[0]), 1);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.BothCommitted));

    malicious.setBehavior(MaliciousERC721Mock.Behavior.Exact);
    same.claim(terms, lock, SECRET);
    assertEq(token.balanceOf(RECIPIENT), 10 ether);
    assertEq(malicious.ownerOf(10), RECIPIENT);
    assertEq(same.reserved(partyAssets[0]), 0);
    assertEq(same.reserved(counterpartyAssets[0]), 0);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Claimed));
  }

  function test_reserveDeficitCannotDrainAnotherTrade() public {
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(token), 0, 10 ether);
    (ProtocolTerms memory first, bytes32 firstLock) =
      _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 7);
    (ProtocolTerms memory second, bytes32 secondLock) =
      _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 8);
    token.mint(alice, 20 ether);
    vm.prank(alice);
    token.approve(address(cross), 20 ether);
    _directCommit(first, true, firstLock, 7, alice, aliceKey, bytes32(0));
    _directCommit(second, true, secondLock, 8, alice, aliceKey, bytes32(0));
    token.burn(address(cross), 10 ether);

    vm.expectRevert(AssetCustody.InsufficientReservedBalance.selector);
    cross.claim(first, true, firstLock, SECRET);
    assertEq(uint8(cross.state(first, true, firstLock)), uint8(CrossChainLegState.Committed));
    assertEq(uint8(cross.state(second, true, secondLock)), uint8(CrossChainLegState.Committed));
  }

  function test_nativeRecipientCannotReenterProductionWrapper() public {
    ReentrantRecipient attacker = new ReentrantRecipient();
    Asset[] memory assets = _oneAsset(AssetType.Native, address(0), 0, 1 ether);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 9);
    terms.partySide.recipient = address(attacker);
    _rebindCross(terms);
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 9);
    vm.deal(alice, 1 ether);
    vm.prank(alice);
    gateway.authorizeCommit{value: 1 ether}(request, _signature(request, address(gateway), aliceKey));
    attacker.arm(address(cross), abi.encodeCall(cross.claim, (terms, true, lock, SECRET)));

    cross.claim(terms, true, lock, SECRET);

    assertTrue(attacker.reentered());
    assertFalse(attacker.innerSucceeded());
    assertEq(address(attacker).balance, 1 ether);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_nativeReclaimRecipientCannotReenterCrossChainWrapper() public {
    ReentrantRecipient attacker = new ReentrantRecipient();
    Asset[] memory assets = _oneAsset(AssetType.Native, address(0), 0, 1 ether);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 30);
    terms.partySide.reclaimRecipient = address(attacker);
    _rebindCross(terms);
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 30);
    vm.deal(alice, 1 ether);
    vm.prank(alice);
    gateway.authorizeCommit{value: 1 ether}(request, _signature(request, address(gateway), aliceKey));
    attacker.arm(address(cross), abi.encodeCall(cross.reclaim, (terms, true, lock)));

    vm.warp(terms.partySide.reclaimRelease);
    cross.reclaim(terms, true, lock);

    assertTrue(attacker.reentered());
    assertFalse(attacker.innerSucceeded());
    assertEq(address(attacker).balance, 1 ether);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Reclaimed));
  }

  function test_nativeRecipientCannotReenterSameChainDualClaim() public {
    ReentrantRecipient attacker = new ReentrantRecipient();
    (ProtocolTerms memory terms, bytes32 lock) =
      _sameChainNativeTerms(address(attacker), RECIPIENT, RECLAIMER, RECLAIMER);
    _commitSameChainNative(terms, lock, 31);
    attacker.arm(address(same), abi.encodeCall(same.claim, (terms, lock, SECRET)));

    same.claim(terms, lock, SECRET);

    assertTrue(attacker.reentered());
    assertFalse(attacker.innerSucceeded());
    assertEq(address(attacker).balance, 1 ether);
    assertEq(RECIPIENT.balance, 2 ether);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Claimed));
  }

  function test_nativeReclaimRecipientCannotReenterSameChainDualReclaim() public {
    ReentrantRecipient attacker = new ReentrantRecipient();
    (ProtocolTerms memory terms, bytes32 lock) =
      _sameChainNativeTerms(RECIPIENT, RECIPIENT, address(attacker), RECLAIMER);
    _commitSameChainNative(terms, lock, 31);
    attacker.arm(address(same), abi.encodeCall(same.reclaimBoth, (terms, lock)));

    vm.warp(terms.counterpartySide.reclaimRelease);
    same.reclaimBoth(terms, lock);

    assertTrue(attacker.reentered());
    assertFalse(attacker.innerSucceeded());
    assertEq(address(attacker).balance, 1 ether);
    assertEq(RECLAIMER.balance, 2 ether);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Reclaimed));
  }

  function test_pairedWrapperRejectsMissingSignedPolicyThenAcceptsExactPolicy() public {
    TimingPolicyRegistry otherPolicies = new TimingPolicyRegistry(address(this));
    TimingPolicy memory mismatched = TimingPolicy(1, WrapperMode.CrossChain, block.chainid, block.chainid + 1, 11, 10);
    otherPolicies.registerPolicy(ProtocolHashing.timingPolicyId(mismatched), mismatched);
    CrossChainWrapper otherCross = new CrossChainWrapper(address(gateway), otherPolicies, assetSupport);
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(token), 0, 10 ether);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 90);
    CommitAuthorizationRequest memory request = _request(address(otherCross), terms, true, lock, 90);
    bytes memory signature = _signature(request, address(gateway), aliceKey);
    token.mint(alice, 10 ether);
    vm.prank(alice);
    token.approve(address(otherCross), 10 ether);

    vm.expectRevert(
      abi.encodeWithSelector(ITimingPolicyRegistry.TimingPolicyNotRegistered.selector, terms.timingPolicyId)
    );
    vm.prank(alice);
    gateway.authorizeCommit(request, signature);
    assertEq(token.balanceOf(alice), 10 ether);
    assertEq(token.balanceOf(address(otherCross)), 0);
    assertEq(uint8(otherCross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));

    TimingPolicy memory exact = TimingPolicy(1, WrapperMode.CrossChain, block.chainid, block.chainid + 1, 10, 10);
    assertEq(ProtocolHashing.timingPolicyId(exact), terms.timingPolicyId);
    otherPolicies.registerPolicy(terms.timingPolicyId, exact);
    vm.prank(alice);
    gateway.authorizeCommit(request, signature);
    assertEq(token.balanceOf(address(otherCross)), 10 ether);
    assertEq(uint8(otherCross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
  }

  function test_crossChainClaimReclaimWinnerMakesStateAndPayoutTerminal() public {
    Asset[] memory assets = _oneAsset(AssetType.Native, address(0), 0, 1 ether);
    (ProtocolTerms memory claimedTerms, bytes32 claimedLock) =
      _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 80);
    CommitAuthorizationRequest memory claimedRequest = _request(address(cross), claimedTerms, true, claimedLock, 80);
    vm.deal(alice, 1 ether);
    vm.prank(alice);
    gateway.authorizeCommit{value: 1 ether}(claimedRequest, _signature(claimedRequest, address(gateway), aliceKey));
    cross.claim(claimedTerms, true, claimedLock, SECRET);
    uint256 paidAfterClaim = RECIPIENT.balance;
    vm.warp(claimedTerms.partySide.reclaimRelease);
    vm.expectRevert(
      abi.encodeWithSelector(
        CrossChainStateMachine.InvalidCrossChainState.selector, CrossChainLegState.Committed, CrossChainLegState.Claimed
      )
    );
    cross.reclaim(claimedTerms, true, claimedLock);
    assertEq(RECIPIENT.balance, paidAfterClaim);
    assertEq(cross.reserved(assets[0]), 0);

    vm.warp(100);
    (ProtocolTerms memory reclaimedTerms, bytes32 reclaimedLock) =
      _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 81);
    CommitAuthorizationRequest memory reclaimedRequest =
      _request(address(cross), reclaimedTerms, true, reclaimedLock, 81);
    vm.deal(alice, 1 ether);
    vm.prank(alice);
    gateway.authorizeCommit{value: 1 ether}(reclaimedRequest, _signature(reclaimedRequest, address(gateway), aliceKey));
    vm.warp(reclaimedTerms.partySide.reclaimRelease);
    cross.reclaim(reclaimedTerms, true, reclaimedLock);
    uint256 refundedAfterReclaim = RECLAIMER.balance;
    vm.warp(100);
    vm.expectRevert(
      abi.encodeWithSelector(
        CrossChainStateMachine.InvalidCrossChainState.selector,
        CrossChainLegState.Committed,
        CrossChainLegState.Reclaimed
      )
    );
    cross.claim(reclaimedTerms, true, reclaimedLock, SECRET);
    assertEq(RECLAIMER.balance, refundedAfterReclaim);
    assertEq(cross.reserved(assets[0]), 0);
  }

  function test_sameChainClaimReclaimWinnerMakesStateAndBothPayoutsTerminal() public {
    (ProtocolTerms memory claimedTerms, bytes32 claimedLock) =
      _sameChainNativeTerms(RECIPIENT, RECIPIENT, RECLAIMER, RECLAIMER);
    _commitSameChainNative(claimedTerms, claimedLock, 41);
    same.claim(claimedTerms, claimedLock, SECRET);
    uint256 paidAfterClaim = RECIPIENT.balance;
    vm.warp(claimedTerms.counterpartySide.reclaimRelease);
    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector, SameChainState.BothCommitted, SameChainState.Claimed
      )
    );
    same.reclaimBoth(claimedTerms, claimedLock);
    assertEq(RECIPIENT.balance, paidAfterClaim);
    assertEq(same.reserved(claimedTerms.partySide.assets[0]), 0);

    vm.warp(100);
    (ProtocolTerms memory reclaimedTerms, bytes32 reclaimedLock) =
      _sameChainNativeTerms(RECIPIENT, RECIPIENT, RECLAIMER, RECLAIMER);
    reclaimedTerms.partySide.sideNonce = bytes32(uint256(201));
    reclaimedTerms.counterpartySide.sideNonce = bytes32(uint256(202));
    reclaimedLock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(reclaimedTerms), SECRET);
    _commitSameChainNative(reclaimedTerms, reclaimedLock, 51);
    vm.warp(reclaimedTerms.counterpartySide.reclaimRelease);
    same.reclaimBoth(reclaimedTerms, reclaimedLock);
    uint256 refundedAfterReclaim = RECLAIMER.balance;
    vm.warp(100);
    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector, SameChainState.BothCommitted, SameChainState.Reclaimed
      )
    );
    same.claim(reclaimedTerms, reclaimedLock, SECRET);
    assertEq(RECLAIMER.balance, refundedAfterReclaim);
    assertEq(same.reserved(reclaimedTerms.partySide.assets[0]), 0);
  }

  function test_sameChainProductionWrapperCommitsAndSettlesBothPrincipalFundedLegs() public {
    ERC20Mock bobToken = new ERC20Mock('Bob', 'BOB', 18);
    ProtocolTerms memory terms;
    terms.partySide =
      _side(alice, AuthorizationMode.RegisteredDirect, 1, _oneAsset(AssetType.ERC20, address(token), 0, 10 ether), 1);
    terms.counterpartySide =
      _side(bob, AuthorizationMode.RegisteredDirect, 1, _oneAsset(AssetType.ERC20, address(bobToken), 0, 20 ether), 2);
    terms.counterpartySide.commitmentDeadline = 220;
    terms.counterpartySide.claimDeadline = 320;
    terms.counterpartySide.reclaimRelease = 520;
    TimingPolicy memory policy = TimingPolicy(1, WrapperMode.SameChain, block.chainid, block.chainid, 0, 0);
    terms.timingPolicyId = ProtocolHashing.timingPolicyId(policy);
    policies.registerPolicy(terms.timingPolicyId, policy);
    bytes32 lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    token.mint(alice, 10 ether);
    bobToken.mint(bob, 20 ether);
    vm.prank(alice);
    token.approve(address(same), 10 ether);
    vm.prank(bob);
    bobToken.approve(address(same), 20 ether);

    _directCommitTo(address(same), terms, true, lock, 9, alice, aliceKey, bytes32(0));
    _directCommitTo(address(same), terms, false, lock, 10, bob, bobKey, bytes32(0));
    vm.prank(RELAYER);
    same.claim(terms, lock, SECRET);

    assertEq(token.balanceOf(RECIPIENT), 10 ether);
    assertEq(bobToken.balanceOf(RECIPIENT), 20 ether);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Claimed));
  }

  function _sameChainNativeTerms(
    address partyRecipient,
    address counterpartyRecipient,
    address partyReclaimer,
    address counterpartyReclaimer
  ) internal returns (ProtocolTerms memory terms, bytes32 lock) {
    terms.partySide = _side(
      alice, AuthorizationMode.RegisteredDirect, 1, _oneAsset(AssetType.Native, address(0), 0, 1 ether), 31
    );
    terms.counterpartySide =
      _side(bob, AuthorizationMode.RegisteredDirect, 1, _oneAsset(AssetType.Native, address(0), 0, 2 ether), 132);
    terms.partySide.recipient = partyRecipient;
    terms.counterpartySide.recipient = counterpartyRecipient;
    terms.partySide.reclaimRecipient = partyReclaimer;
    terms.counterpartySide.reclaimRecipient = counterpartyReclaimer;
    TimingPolicy memory policy = TimingPolicy(1, WrapperMode.SameChain, block.chainid, block.chainid, 0, 0);
    terms.timingPolicyId = ProtocolHashing.timingPolicyId(policy);
    if (!policies.isRegistered(terms.timingPolicyId)) policies.registerPolicy(terms.timingPolicyId, policy);
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
  }

  function _commitSameChainNative(ProtocolTerms memory terms, bytes32 lock, uint256 nonceBase) internal {
    vm.deal(alice, 1 ether);
    vm.deal(bob, 2 ether);
    CommitAuthorizationRequest memory partyRequest = _request(address(same), terms, true, lock, nonceBase);
    vm.prank(alice);
    gateway.authorizeCommit{value: 1 ether}(partyRequest, _signature(partyRequest, address(gateway), aliceKey));
    CommitAuthorizationRequest memory counterpartyRequest = _request(address(same), terms, false, lock, nonceBase + 1);
    vm.prank(bob);
    gateway.authorizeCommit{value: 2 ether}(
      counterpartyRequest, _signature(counterpartyRequest, address(gateway), bobKey)
    );
  }

  function _directCommit(
    ProtocolTerms memory terms,
    bool party,
    bytes32 lock,
    uint256 nonce,
    address caller,
    bytes memory key,
    bytes32 progressionSecret
  ) internal {
    _directCommitTo(address(cross), terms, party, lock, nonce, caller, key, progressionSecret);
  }

  function _directCommitTo(
    address receiver,
    ProtocolTerms memory terms,
    bool party,
    bytes32 lock,
    uint256 nonce,
    address caller,
    bytes memory key,
    bytes32 progressionSecret
  ) internal {
    CommitAuthorizationRequest memory request = _request(receiver, terms, party, lock, nonce);
    request.bobCommitSecret = progressionSecret;
    vm.prank(caller);
    gateway.authorizeCommit(request, _signature(request, address(gateway), key));
  }

  function _crossTerms(
    address principal,
    AuthorizationMode mode,
    uint256 version,
    Asset[] memory assets,
    uint256 nonce
  ) internal returns (ProtocolTerms memory terms, bytes32 lock) {
    terms.partySide = _side(principal, mode, version, assets, nonce);
    terms.counterpartySide =
      _side(bob, AuthorizationMode.RegisteredDirect, 1, _oneAsset(AssetType.Native, address(0), 0, 1), nonce + 100);
    terms.counterpartySide.chainId = block.chainid + 1;
    TimingPolicy memory policy = TimingPolicy(1, WrapperMode.CrossChain, block.chainid, block.chainid + 1, 10, 10);
    terms.timingPolicyId = ProtocolHashing.timingPolicyId(policy);
    terms.counterpartySide.commitLock =
      ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), BOB_COMMIT_SECRET);
    if (!policies.isRegistered(terms.timingPolicyId)) policies.registerPolicy(terms.timingPolicyId, policy);
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
  }

  function _rebindCross(ProtocolTerms memory terms) internal pure {
    terms.counterpartySide.commitLock = bytes32(0);
    terms.counterpartySide.commitLock =
      ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), BOB_COMMIT_SECRET);
  }

  function _side(
    address principal,
    AuthorizationMode mode,
    uint256 version,
    Asset[] memory assets,
    uint256 nonce
  ) internal returns (SideTerms memory side) {
    _supportAssets(assets);
    side.chainId = block.chainid;
    side.assets = assets;
    side.principal = principal;
    side.authorizationMode = mode;
    side.principalKeyVersion = version;
    side.reclaimRecipient = RECLAIMER;
    side.recipient = RECIPIENT;
    side.commitmentDeadline = 200;
    side.claimDeadline = 300;
    side.reclaimRelease = 500;
    side.delegationPolicy = DelegationPolicy.NotAllowed;
    side.sideNonce = bytes32(nonce);
    if (nonce >= 100) {
      side.commitmentDeadline = 220;
      side.claimDeadline = 320;
      side.reclaimRelease = 520;
    }
  }

  function _supportAssets(Asset[] memory assets) internal {
    for (uint256 i; i < assets.length; ++i) {
      if (assets[i].assetType != AssetType.Native) {
        assetSupport.setAssetSupport(assets[i].assetType, assets[i].target, true);
      }
    }
  }

  function _request(
    address receiver,
    ProtocolTerms memory terms,
    bool party,
    bytes32 lock,
    uint256 nonce
  ) internal pure returns (CommitAuthorizationRequest memory request) {
    request.receiver = receiver;
    request.terms = terms;
    request.party = party;
    request.lock = lock;
    request.actionNonce = bytes32(nonce);
    request.expiry = 190;
  }

  function _signature(
    CommitAuthorizationRequest memory request,
    address boundary,
    bytes memory key
  ) internal pure returns (bytes memory) {
    bytes32 payload = ProtocolHashing.commitPayloadHash(
      request.terms,
      request.party,
      boundary,
      request.receiver,
      request.lock,
      ProtocolHashing.expectedSourceState(request.party, ProtocolHashing.mode(request.terms)),
      request.actionNonce,
      request.expiry
    );
    return _pqSig(key, payload);
  }

  function _oneAsset(
    AssetType assetType,
    address target,
    uint256 id,
    uint256 amount
  ) internal pure returns (Asset[] memory assets) {
    assets = new Asset[](1);
    assets[0] = Asset(assetType, target, id, amount);
  }

  function _register(address eoa, bytes memory key) internal {
    InitialRegistration memory request = InitialRegistration({
      eoa: eoa,
      activePQKey: key,
      recoveryPQKey: _key('recovery'),
      commitTarget: address(registrationTarget),
      commitPayloadHash: keccak256('registration'),
      operationNonce: keccak256(abi.encode(eoa)),
      expiry: 190
    });
    bytes32 digest = registry.registrationDigest(request);
    bytes32 activeProof = keccak256(abi.encode('InterlockKeyPossession-v1.1', digest, KeyRole.Active, keccak256(key)));
    bytes32 recoveryProof =
      keccak256(abi.encode('InterlockKeyPossession-v1.1', digest, KeyRole.Recovery, keccak256(request.recoveryPQKey)));
    vm.prank(eoa);
    registry.registerAndCommit(request, '', _pqSig(key, activeProof), _pqSig(request.recoveryPQKey, recoveryProof), '');
  }

  function _key(string memory label) internal view returns (bytes memory) {
    return abi.encodePacked(address(verifier), bytes(label));
  }

  function _pqSig(bytes memory keyedVerifier, bytes32 digest) internal pure returns (bytes memory) {
    bytes memory key = new bytes(keyedVerifier.length - 20);
    for (uint256 i; i < key.length; ++i) {
      key[i] = keyedVerifier[i + 20];
    }
    return abi.encode(key, digest);
  }
}
