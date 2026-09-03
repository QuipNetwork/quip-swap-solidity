// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetCustody} from '../../src/assets/AssetHandling.sol';
import {AssetSupport} from '../../src/assets/AssetHandling.sol';
import {AssetSupportRegistry} from '../../src/assets/AssetSupportRegistry.sol';
import {DirectAuthorization} from '../../src/authorization/direct/DirectAuthorization.sol';
import {AuthorizationSubmitter} from '../../src/authorization/shared/AuthorizationSubmitter.sol';
import {QuipWallet} from '../../src/authorization/wallet/QuipWallet.sol';
import {ProgressionGate} from '../../src/protocol/CommitValidation.sol';
import {CrossChainWrapper} from '../../src/protocol/CrossChainWrapper.sol';
import {ProtocolHashing} from '../../src/protocol/ProtocolHashing.sol';
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
  WrapperMode
} from '../../src/protocol/ProtocolTypes.sol';
import {Asset, AssetType} from '../../src/protocol/ProtocolTypes.sol';
import {SameChainWrapper} from '../../src/protocol/SameChainWrapper.sol';
import {Settlement} from '../../src/protocol/Settlement.sol';
import {CrossChainStateMachine} from '../../src/protocol/StateMachines.sol';
import {SameChainStateMachine} from '../../src/protocol/StateMachines.sol';
import {SwapHTLC} from '../../src/protocol/SwapHTLC.sol';
import {RegisteredCommitTargetHarness} from '../harness/RegisteredCommitTargetHarness.sol';
import {AdversarialERC20Mock} from '../mocks/AdversarialERC20Mock.sol';
import {ERC1155Mock} from '../mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';
import {FeeOnTransferERC20Mock} from '../mocks/FeeOnTransferERC20Mock.sol';
import {KeyBoundVerifierMock} from '../mocks/KeyBoundVerifierMock.sol';
import {MaliciousERC20Mock} from '../mocks/MaliciousERC20Mock.sol';
import {MaliciousERC721Mock} from '../mocks/MaliciousERC721Mock.sol';
import {ReentrantERC1155Mock, ReentrantERC1155Recipient} from '../mocks/ReentrantERC1155Mock.sol';
import {ReentrantRecipient} from '../mocks/ReentrantRecipient.sol';
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
  bytes internal bobWalletKey;

  KeyBoundVerifierMock internal verifier;
  DirectAuthorization internal registry;
  DirectAuthorization internal gateway;
  AssetSupportRegistry internal assetSupport;
  CrossChainWrapper internal cross;
  SameChainWrapper internal same;
  QuipWallet internal wallet;
  QuipWallet internal bobWallet;
  RegisteredCommitTargetHarness internal registrationTarget;
  ERC20Mock internal token;
  SwapHTLC internal htlcImplementation;

  function setUp() public {
    vm.warp(100);
    alice = vm.addr(ALICE_PRIVATE);
    bob = vm.addr(BOB_PRIVATE);
    broker = vm.addr(BROKER_PRIVATE);
    verifier = new KeyBoundVerifierMock();
    registry = new DirectAuthorization(address(verifier));
    registrationTarget = new RegisteredCommitTargetHarness();
    aliceKey = _key('alice');
    bobKey = _key('bob');
    brokerKey = _key('broker');
    walletKey = _key('wallet');
    bobWalletKey = _key('bob-wallet');
    _register(alice, aliceKey);
    _register(bob, bobKey);
    _register(broker, brokerKey);
    gateway = registry;
    assetSupport = new AssetSupportRegistry(address(this));
    htlcImplementation = new SwapHTLC();
    cross = new CrossChainWrapper(address(gateway), assetSupport, address(htlcImplementation), address(this));
    same = new SameChainWrapper(address(gateway), assetSupport, address(htlcImplementation), address(this));
    wallet = new QuipWallet(address(this), registry, walletKey);
    bobWallet = new QuipWallet(bob, registry, bobWalletKey);
    token = new ERC20Mock('Token', 'TOK', 18);
  }

  function test_directBrokerTransportsButPrincipalFundsERC20() public {
    uint256 fee = 0.004 ether;
    cross.setCommitmentFee(fee);
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
    vm.deal(broker, fee);
    vm.prank(broker);
    gateway.authorizeCommit{value: fee}(request, _signature(request, address(gateway), aliceKey));

    address htlc = cross.htlcOf(terms, true, lock);
    assertEq(htlc, cross.predictHTLC(terms, true, lock));
    assertGt(htlc.code.length, 0);
    assertEq(token.balanceOf(htlc), 10 ether);
    assertEq(token.balanceOf(address(cross)), 0);
    assertEq(token.balanceOf(broker), 0);
    assertTrue(SwapHTLC(payable(htlc)).funded());
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
    assertEq(cross.accruedFees(), fee);

    cross.claim(terms, true, lock, SECRET);
    assertEq(token.balanceOf(RECIPIENT), 10 ether);
    assertEq(token.balanceOf(htlc), 0);
    assertTrue(SwapHTLC(payable(htlc)).released());
  }

  function test_allDemoInvalidActionsRevertAtomicallyInOneSession() public {
    uint256 partyChainId = block.chainid;
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(token), 0, 10 ether);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 91);

    token.mint(alice, 10 ether);
    vm.prank(alice);
    token.approve(address(cross), 10 ether);
    _directCommit(terms, true, lock, 91, alice, aliceKey, bytes32(0));
    address partyHTLC = cross.htlcOf(terms, true, lock);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
    assertEq(token.balanceOf(partyHTLC), 10 ether);

    vm.chainId(terms.counterpartySide.chainId);
    vm.deal(bob, 1);
    vm.deal(broker, 1);
    CommitAuthorizationRequest memory bobRequest = _request(address(cross), terms, false, lock, 902);
    bytes memory bobSignature = _signature(bobRequest, address(gateway), bobKey);

    bobRequest.bobCommitSecret = BOB_COMMIT_SECRET;
    vm.expectRevert(AuthorizationSubmitter.InvalidTransportSubmitter.selector);
    vm.prank(broker);
    gateway.authorizeCommit{value: 1}(bobRequest, bobSignature);

    bobRequest.bobCommitSecret = bytes32(0);
    vm.expectRevert(ProgressionGate.MissingBobCommitSecret.selector);
    vm.prank(bob);
    gateway.authorizeCommit{value: 1}(bobRequest, bobSignature);

    bobRequest.bobCommitSecret = keccak256('wrong-bob-commit-secret');
    vm.expectRevert(ProgressionGate.InvalidBobCommitSecret.selector);
    vm.prank(bob);
    gateway.authorizeCommit{value: 1}(bobRequest, bobSignature);

    assertEq(uint8(cross.state(terms, false, lock)), uint8(CrossChainLegState.Unused));
    assertEq(address(cross).balance, 0);
    assertEq(bob.balance, 1);

    bobRequest.bobCommitSecret = BOB_COMMIT_SECRET;
    vm.prank(bob);
    gateway.authorizeCommit{value: 1}(bobRequest, bobSignature);
    assertEq(uint8(cross.state(terms, false, lock)), uint8(CrossChainLegState.Committed));
    assertEq(cross.htlcOf(terms, false, lock).balance, 1);
    assertEq(address(cross).balance, 0);

    vm.chainId(partyChainId);
    vm.expectRevert(Settlement.InvalidSettlementSecret.selector);
    cross.claim(terms, true, lock, keccak256('wrong-final-claim-secret'));
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
    assertEq(token.balanceOf(partyHTLC), 10 ether);
    assertEq(token.balanceOf(RECIPIENT), 0);
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
    cross.setCommitmentFee(0.004 ether);
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
    vm.deal(newcomer, 0.008 ether);

    vm.expectRevert(DirectAuthorization.CommitCallbackFailed.selector);
    vm.prank(newcomer);
    registry.registerAndCommit{value: 0.004 ether}(registration, '', activeProof, recoveryProof, commitData);
    assertEq(registry.identityOf(newcomer).activeKeyVersion, 0);
    assertEq(token.balanceOf(newcomer), 10 ether);
    assertEq(token.balanceOf(address(cross)), 0);
    assertEq(cross.predictHTLC(terms, true, lock).code.length, 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));
    assertEq(cross.accruedFees(), 0);
    assertEq(address(cross).balance, 0);

    vm.prank(newcomer);
    token.approve(address(cross), 10 ether);
    vm.prank(newcomer);
    registry.registerAndCommit{value: 0.004 ether}(registration, '', activeProof, recoveryProof, commitData);
    assertEq(registry.identityOf(newcomer).activeKeyVersion, 1);
    assertEq(token.balanceOf(newcomer), 0);
    assertEq(token.balanceOf(cross.htlcOf(terms, true, lock)), 10 ether);
    assertEq(token.balanceOf(address(cross)), 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
    assertEq(cross.accruedFees(), 0.004 ether);
    assertEq(address(cross).balance, 0.004 ether);
  }

  function test_walletPrincipalFundsTokenWhileRelayerOnlyTransports() public {
    uint256 fee = 0.004 ether;
    cross.setCommitmentFee(fee);
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(token), 0, 10 ether);
    (ProtocolTerms memory terms, bytes32 lock) =
      _crossTerms(address(wallet), AuthorizationMode.QuipWallet, 0, assets, 3);
    terms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    _rebindCross(terms);
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    token.mint(address(wallet), 10 ether);
    wallet.execute(address(token), 0, abi.encodeCall(token.approve, (address(cross), 10 ether)));
    CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, 3);

    bytes memory signature = _signature(request, address(wallet), walletKey);
    vm.deal(RELAYER, fee);
    vm.prank(RELAYER);
    wallet.authorizeCommit{value: fee}(request, signature);

    assertEq(token.balanceOf(cross.htlcOf(terms, true, lock)), 10 ether);
    assertEq(token.balanceOf(address(cross)), 0);
    assertEq(token.balanceOf(RELAYER), 0);
    assertEq(cross.accruedFees(), fee);
    assertEq(address(cross).balance, fee);
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

    assertEq(cross.htlcOf(terms, true, lock).balance, 1 ether);
    assertEq(address(cross).balance, 0);
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

    address htlc = cross.htlcOf(terms, true, lock);
    assertEq(nft.ownerOf(7), htlc);
    assertEq(multi.balanceOf(htlc, 9), 3);
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
    assertEq(cross.predictHTLC(terms, true, lock).code.length, 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));

    assetSupport.setAssetSupport(AssetType.ERC20, address(unsupported), true);
    vm.prank(alice);
    gateway.authorizeCommit(request, signature);
    assertEq(unsupported.balanceOf(cross.htlcOf(terms, true, lock)), 10 ether);
    assertEq(unsupported.balanceOf(address(cross)), 0);
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
    assertTrue(SwapHTLC(payable(cross.htlcOf(terms, true, lock))).released());
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_maliciousIncomingERC20BehaviorsRevertAtomicallyAndPermitRetry() public {
    for (uint8 raw = 1; raw <= uint8(MaliciousERC20Mock.Behavior.ReturnFalse); ++raw) {
      MaliciousERC20Mock malicious = new MaliciousERC20Mock();
      Asset[] memory assets = _oneAsset(AssetType.ERC20, address(malicious), 0, 10 ether);
      uint256 nonce = 60 + raw;
      (ProtocolTerms memory terms, bytes32 lock) =
        _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, (80 + raw));
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
      assertEq(cross.predictHTLC(terms, true, lock).code.length, 0);
      assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));

      malicious.setBehavior(MaliciousERC20Mock.Behavior.Exact);
      vm.prank(alice);
      gateway.authorizeCommit(request, signature);
      assertEq(malicious.balanceOf(cross.htlcOf(terms, true, lock)), 10 ether);
      assertEq(malicious.balanceOf(address(cross)), 0);
      assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
    }
  }

  function test_maliciousNoOpPayoutRollsBackClaimAndHTLCState() public {
    MaliciousERC20Mock malicious = new MaliciousERC20Mock();
    Asset[] memory assets = _oneAsset(AssetType.ERC20, address(malicious), 0, 10 ether);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 70);
    malicious.mint(alice, 10 ether);
    vm.prank(alice);
    malicious.approve(address(cross), 10 ether);
    _directCommit(terms, true, lock, 70, alice, aliceKey, bytes32(0));
    address htlc = cross.htlcOf(terms, true, lock);
    malicious.setBehavior(MaliciousERC20Mock.Behavior.NoOp);

    vm.expectRevert(AssetCustody.UnexpectedAmountReceived.selector);
    cross.claim(terms, true, lock, SECRET);
    assertEq(malicious.balanceOf(RECIPIENT), 0);
    assertEq(malicious.balanceOf(htlc), 10 ether);
    assertFalse(SwapHTLC(payable(htlc)).released());
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));

    malicious.setBehavior(MaliciousERC20Mock.Behavior.Exact);
    cross.claim(terms, true, lock, SECRET);
    assertEq(malicious.balanceOf(RECIPIENT), 10 ether);
    assertTrue(SwapHTLC(payable(htlc)).released());
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
    address predicted = cross.predictHTLC(terms, true, lock);

    vm.expectRevert(abi.encodeWithSelector(AssetCustody.UnexpectedERC721Owner.selector, predicted, alice));
    vm.prank(alice);
    gateway.authorizeCommit(request, signature);
    assertEq(malicious.ownerOf(7), alice);
    assertEq(predicted.code.length, 0);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));

    malicious.setBehavior(MaliciousERC721Mock.Behavior.Exact);
    vm.prank(alice);
    gateway.authorizeCommit(request, signature);
    assertEq(malicious.ownerOf(7), predicted);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
  }

  function test_duplicateERC721ReferencesCannotCreateMultipleEscrows() public {
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
    assertEq(cross.predictHTLC(terms, true, lock).code.length, 0);
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
    address htlc = cross.htlcOf(terms, true, lock);
    malicious.setBehavior(MaliciousERC721Mock.Behavior.NoOp);

    vm.expectRevert(abi.encodeWithSelector(AssetCustody.UnexpectedERC721Owner.selector, RECIPIENT, htlc));
    cross.claim(terms, true, lock, SECRET);
    assertEq(malicious.ownerOf(8), htlc);
    assertFalse(SwapHTLC(payable(htlc)).released());
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));

    malicious.setBehavior(MaliciousERC721Mock.Behavior.Exact);
    cross.claim(terms, true, lock, SECRET);
    assertEq(malicious.ownerOf(8), RECIPIENT);
    assertTrue(SwapHTLC(payable(htlc)).released());
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
    address htlc = cross.htlcOf(terms, true, lock);
    vm.warp(terms.partySide.reclaimRelease);
    malicious.setBehavior(MaliciousERC721Mock.Behavior.NoOp);

    vm.expectRevert(abi.encodeWithSelector(AssetCustody.UnexpectedERC721Owner.selector, RECLAIMER, htlc));
    cross.reclaim(terms, true, lock);
    assertEq(malicious.ownerOf(9), htlc);
    assertFalse(SwapHTLC(payable(htlc)).released());
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));

    malicious.setBehavior(MaliciousERC721Mock.Behavior.Exact);
    cross.reclaim(terms, true, lock);
    assertEq(malicious.ownerOf(9), RECLAIMER);
    assertTrue(SwapHTLC(payable(htlc)).released());
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Reclaimed));
  }

  function test_sameChainSecondERC721PayoutFailurePreservesFirstLegProgress() public {
    MaliciousERC721Mock malicious = new MaliciousERC721Mock();
    Asset[] memory partyAssets = _oneAsset(AssetType.ERC20, address(token), 0, 10 ether);
    Asset[] memory counterpartyAssets = _oneAsset(AssetType.ERC721, address(malicious), 10, 1);
    ProtocolTerms memory terms;
    terms.partySide = _side(alice, AuthorizationMode.RegisteredDirect, 1, partyAssets, 74);
    terms.counterpartySide = _side(bob, AuthorizationMode.RegisteredDirect, 1, counterpartyAssets, 174);
    bytes32 lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    token.mint(alice, 10 ether);
    malicious.mint(bob, 10);
    vm.prank(alice);
    token.approve(address(same), 10 ether);
    vm.prank(bob);
    malicious.approve(address(same), 10);
    _directCommitTo(address(same), terms, true, lock, 74, alice, aliceKey, bytes32(0));
    _directCommitTo(address(same), terms, false, lock, 75, bob, bobKey, bytes32(0));
    address partyHTLC = same.htlcOf(terms, true, lock);
    address counterpartyHTLC = same.htlcOf(terms, false, lock);
    malicious.setBehavior(MaliciousERC721Mock.Behavior.NoOp);

    same.selectClaim(terms, lock, SECRET);
    same.executeSettlement(terms, lock, true, 1);
    vm.expectRevert(abi.encodeWithSelector(AssetCustody.UnexpectedERC721Owner.selector, RECIPIENT, counterpartyHTLC));
    same.executeSettlement(terms, lock, false, 1);
    assertEq(token.balanceOf(RECIPIENT), 10 ether);
    assertEq(token.balanceOf(partyHTLC), 0);
    assertEq(malicious.ownerOf(10), counterpartyHTLC);
    assertTrue(SwapHTLC(payable(partyHTLC)).released());
    assertFalse(SwapHTLC(payable(counterpartyHTLC)).released());
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.ClaimPending));

    malicious.setBehavior(MaliciousERC721Mock.Behavior.Exact);
    same.executeSettlement(terms, lock, false, 1);
    assertEq(token.balanceOf(RECIPIENT), 10 ether);
    assertEq(malicious.ownerOf(10), RECIPIENT);
    assertTrue(SwapHTLC(payable(partyHTLC)).released());
    assertTrue(SwapHTLC(payable(counterpartyHTLC)).released());
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Claimed));
  }

  function test_erc721OwnerQueryFailuresAfterCollectionRollbackAndPermitAuthorizationRetry() public {
    for (
      uint8 raw = uint8(MaliciousERC721Mock.Behavior.OwnerQueryReverts);
      raw <= uint8(MaliciousERC721Mock.Behavior.OwnerQueryWrong);
      ++raw
    ) {
      MaliciousERC721Mock malicious = new MaliciousERC721Mock();
      uint256 tokenId = 100 + raw;
      uint256 nonce = 200 + raw;
      Asset[] memory assets = _oneAsset(AssetType.ERC721, address(malicious), tokenId, 1);
      (ProtocolTerms memory terms, bytes32 lock) =
        _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, (89 + raw));
      CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, nonce);
      bytes memory signature = _signature(request, address(gateway), aliceKey);
      malicious.mint(alice, tokenId);
      vm.prank(alice);
      malicious.approve(address(cross), tokenId);
      malicious.setBehavior(MaliciousERC721Mock.Behavior(raw));
      address predicted = cross.predictHTLC(terms, true, lock);

      address reported = raw == uint8(MaliciousERC721Mock.Behavior.OwnerQueryReverts) ? address(0) : address(0xBAD);
      vm.expectRevert(abi.encodeWithSelector(AssetCustody.UnexpectedERC721Owner.selector, predicted, reported));
      vm.prank(alice);
      gateway.authorizeCommit(request, signature);
      assertEq(malicious.actualOwnerOf(tokenId), alice);
      assertEq(predicted.code.length, 0);
      assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));

      malicious.setBehavior(MaliciousERC721Mock.Behavior.Exact);
      vm.prank(alice);
      gateway.authorizeCommit(request, signature);
      assertEq(malicious.actualOwnerOf(tokenId), predicted);
      assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
    }
  }

  function test_erc721OwnerQueryFailuresAfterPayoutRollbackAndPermitClaimRetry() public {
    for (
      uint8 raw = uint8(MaliciousERC721Mock.Behavior.TransferThenOwnerQueryReverts);
      raw <= uint8(MaliciousERC721Mock.Behavior.TransferThenOwnerQueryWrong);
      ++raw
    ) {
      MaliciousERC721Mock malicious = new MaliciousERC721Mock();
      uint256 tokenId = 110 + raw;
      uint256 nonce = 210 + raw;
      Asset[] memory assets = _oneAsset(AssetType.ERC721, address(malicious), tokenId, 1);
      (ProtocolTerms memory terms, bytes32 lock) =
        _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, (84 + raw));
      malicious.mint(alice, tokenId);
      vm.prank(alice);
      malicious.approve(address(cross), tokenId);
      _directCommit(terms, true, lock, nonce, alice, aliceKey, bytes32(0));
      address htlc = cross.htlcOf(terms, true, lock);
      malicious.setBehavior(MaliciousERC721Mock.Behavior(raw));

      address reported =
        raw == uint8(MaliciousERC721Mock.Behavior.TransferThenOwnerQueryReverts) ? address(0) : address(0xBAD);
      vm.expectRevert(abi.encodeWithSelector(AssetCustody.UnexpectedERC721Owner.selector, RECIPIENT, reported));
      cross.claim(terms, true, lock, SECRET);
      assertEq(malicious.actualOwnerOf(tokenId), htlc);
      assertFalse(SwapHTLC(payable(htlc)).released());
      assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));

      malicious.setBehavior(MaliciousERC721Mock.Behavior.Exact);
      cross.claim(terms, true, lock, SECRET);
      assertEq(malicious.actualOwnerOf(tokenId), RECIPIENT);
      assertTrue(SwapHTLC(payable(htlc)).released());
      assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Claimed));
    }
  }

  function test_erc1155TokenCannotReenterDuringCollection() public {
    ReentrantERC1155Mock malicious = new ReentrantERC1155Mock();
    Asset[] memory assets = _oneAsset(AssetType.ERC1155, address(malicious), 7, 3);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 87);
    malicious.mint(alice, 7, 3);
    vm.prank(alice);
    malicious.setApprovalForAll(address(cross), true);
    malicious.arm(address(cross), abi.encodeCall(cross.claim, (terms, true, lock, SECRET)));

    _directCommit(terms, true, lock, 220, alice, aliceKey, bytes32(0));

    assertTrue(malicious.reentered());
    assertFalse(malicious.innerSucceeded());
    assertEq(malicious.balanceOf(cross.htlcOf(terms, true, lock), 7), 3);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
  }

  function test_erc1155RecipientCannotReenterDuringRelease() public {
    ReentrantERC1155Mock token1155 = new ReentrantERC1155Mock();
    ReentrantERC1155Recipient attacker = new ReentrantERC1155Recipient();
    Asset[] memory assets = _oneAsset(AssetType.ERC1155, address(token1155), 8, 4);
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, 88);
    terms.partySide.recipient = address(attacker);
    _rebindCross(terms);
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    token1155.mint(alice, 8, 4);
    vm.prank(alice);
    token1155.setApprovalForAll(address(cross), true);
    _directCommit(terms, true, lock, 221, alice, aliceKey, bytes32(0));
    attacker.arm(address(cross), abi.encodeCall(cross.claim, (terms, true, lock, SECRET)));

    cross.claim(terms, true, lock, SECRET);

    assertTrue(attacker.reentered());
    assertFalse(attacker.innerSucceeded());
    assertEq(token1155.balanceOf(address(attacker), 8), 4);
    assertTrue(SwapHTLC(payable(cross.htlcOf(terms, true, lock))).released());
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_erc20BalanceQueryFailuresDuringCollectionRollbackNonceAndPermitRetry() public {
    for (
      uint8 raw = uint8(AdversarialERC20Mock.BalanceBehavior.RevertQuery);
      raw <= uint8(AdversarialERC20Mock.BalanceBehavior.MalformedQuery);
      ++raw
    ) {
      AdversarialERC20Mock malicious = new AdversarialERC20Mock();
      uint256 nonce = 230 + raw;
      Asset[] memory assets = _oneAsset(AssetType.ERC20, address(malicious), 0, 10 ether);
      (ProtocolTerms memory terms, bytes32 lock) =
        _crossTerms(alice, AuthorizationMode.RegisteredDirect, 1, assets, (89 + raw));
      CommitAuthorizationRequest memory request = _request(address(cross), terms, true, lock, nonce);
      bytes memory signature = _signature(request, address(gateway), aliceKey);
      malicious.mint(alice, 10 ether);
      vm.prank(alice);
      malicious.approve(address(cross), 10 ether);
      address predicted = cross.predictHTLC(terms, true, lock);
      malicious.setBalanceBehavior(AdversarialERC20Mock.BalanceBehavior(raw), predicted);

      vm.expectRevert();
      vm.prank(alice);
      gateway.authorizeCommit(request, signature);
      assertEq(malicious.rawBalanceOf(alice), 10 ether);
      assertEq(malicious.rawBalanceOf(address(cross)), 0);
      assertEq(predicted.code.length, 0);
      assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Unused));

      malicious.setBalanceBehavior(AdversarialERC20Mock.BalanceBehavior.Exact, address(0));
      vm.prank(alice);
      gateway.authorizeCommit(request, signature);
      assertEq(malicious.rawBalanceOf(predicted), 10 ether);
      assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
    }
  }

  function test_sameChainBalanceQueryFailurePreservesCompletedSideForRetry() public {
    for (
      uint8 raw = uint8(AdversarialERC20Mock.BalanceBehavior.RevertQuery);
      raw <= uint8(AdversarialERC20Mock.BalanceBehavior.MalformedQuery);
      ++raw
    ) {
      ERC20Mock partyToken = new ERC20Mock('Party', 'PTY', 18);
      AdversarialERC20Mock malicious = new AdversarialERC20Mock();
      Asset[] memory partyAssets = _oneAsset(AssetType.ERC20, address(partyToken), 0, 10 ether);
      Asset[] memory counterpartyAssets = _oneAsset(AssetType.ERC20, address(malicious), 0, 20 ether);
      ProtocolTerms memory terms;
      terms.partySide = _side(alice, AuthorizationMode.RegisteredDirect, 1, partyAssets, 92 + raw);
      terms.counterpartySide = _side(bob, AuthorizationMode.RegisteredDirect, 1, counterpartyAssets, 192 + raw);
      bytes32 lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
      partyToken.mint(alice, 10 ether);
      malicious.mint(bob, 20 ether);
      vm.prank(alice);
      partyToken.approve(address(same), 10 ether);
      vm.prank(bob);
      malicious.approve(address(same), 20 ether);
      _directCommitTo(address(same), terms, true, lock, 240 + raw, alice, aliceKey, bytes32(0));
      _directCommitTo(address(same), terms, false, lock, 250 + raw, bob, bobKey, bytes32(0));
      address partyHTLC = same.htlcOf(terms, true, lock);
      address counterpartyHTLC = same.htlcOf(terms, false, lock);
      malicious.setBalanceBehavior(AdversarialERC20Mock.BalanceBehavior(raw), RECIPIENT);

      same.selectClaim(terms, lock, SECRET);
      same.executeSettlement(terms, lock, true, 1);
      vm.expectRevert();
      same.executeSettlement(terms, lock, false, 1);
      assertEq(partyToken.balanceOf(RECIPIENT), 10 ether);
      assertEq(partyToken.balanceOf(partyHTLC), 0);
      assertEq(malicious.rawBalanceOf(RECIPIENT), 0);
      assertEq(malicious.rawBalanceOf(counterpartyHTLC), 20 ether);
      assertTrue(SwapHTLC(payable(partyHTLC)).released());
      assertFalse(SwapHTLC(payable(counterpartyHTLC)).released());
      assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.ClaimPending));

      malicious.setBalanceBehavior(AdversarialERC20Mock.BalanceBehavior.Exact, address(0));
      same.executeSettlement(terms, lock, false, 1);
      assertEq(partyToken.balanceOf(RECIPIENT), 10 ether);
      assertEq(malicious.rawBalanceOf(RECIPIENT), 20 ether);
      assertTrue(SwapHTLC(payable(partyHTLC)).released());
      assertTrue(SwapHTLC(payable(counterpartyHTLC)).released());
      assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Claimed));
    }
  }

  function test_oneHTLCDeficitCannotDrainAnotherTrade() public {
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
    address firstHTLC = cross.htlcOf(first, true, firstLock);
    address secondHTLC = cross.htlcOf(second, true, secondLock);
    token.burn(firstHTLC, 10 ether);

    vm.expectRevert();
    cross.claim(first, true, firstLock, SECRET);
    assertEq(uint8(cross.state(first, true, firstLock)), uint8(CrossChainLegState.Committed));
    assertEq(uint8(cross.state(second, true, secondLock)), uint8(CrossChainLegState.Committed));
    assertEq(token.balanceOf(firstHTLC), 0);
    assertEq(token.balanceOf(secondHTLC), 10 ether);
    assertFalse(SwapHTLC(payable(firstHTLC)).released());
    assertFalse(SwapHTLC(payable(secondHTLC)).released());
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
    attacker.arm(address(same), abi.encodeCall(same.executeSettlement, (terms, lock, true, 1)));

    _claimSame(terms, lock);

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
    attacker.arm(address(same), abi.encodeCall(same.executeSettlement, (terms, lock, true, 1)));

    vm.warp(terms.counterpartySide.reclaimRelease);
    _reclaimSameBoth(terms, lock);

    assertTrue(attacker.reentered());
    assertFalse(attacker.innerSucceeded());
    assertEq(address(attacker).balance, 1 ether);
    assertEq(RECLAIMER.balance, 2 ether);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Reclaimed));
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
    assertTrue(SwapHTLC(payable(cross.htlcOf(claimedTerms, true, claimedLock))).released());

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
    assertTrue(SwapHTLC(payable(cross.htlcOf(reclaimedTerms, true, reclaimedLock))).released());
  }

  function test_sameChainClaimReclaimWinnerMakesStateAndBothPayoutsTerminal() public {
    (ProtocolTerms memory claimedTerms, bytes32 claimedLock) =
      _sameChainNativeTerms(RECIPIENT, RECIPIENT, RECLAIMER, RECLAIMER);
    _commitSameChainNative(claimedTerms, claimedLock, 41);
    _claimSame(claimedTerms, claimedLock);
    uint256 paidAfterClaim = RECIPIENT.balance;
    vm.warp(claimedTerms.counterpartySide.reclaimRelease);
    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector, SameChainState.BothCommitted, SameChainState.Claimed
      )
    );
    same.selectReclaim(claimedTerms, claimedLock);
    assertEq(RECIPIENT.balance, paidAfterClaim);
    assertTrue(SwapHTLC(payable(same.htlcOf(claimedTerms, true, claimedLock))).released());
    assertTrue(SwapHTLC(payable(same.htlcOf(claimedTerms, false, claimedLock))).released());

    vm.warp(100);
    (ProtocolTerms memory reclaimedTerms, bytes32 reclaimedLock) =
      _sameChainNativeTerms(RECIPIENT, RECIPIENT, RECLAIMER, RECLAIMER);
    reclaimedTerms.partySide.sideNonce = bytes32(uint256(201));
    reclaimedTerms.counterpartySide.sideNonce = bytes32(uint256(202));
    reclaimedLock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(reclaimedTerms), SECRET);
    _commitSameChainNative(reclaimedTerms, reclaimedLock, 51);
    vm.warp(reclaimedTerms.counterpartySide.reclaimRelease);
    _reclaimSameBoth(reclaimedTerms, reclaimedLock);
    uint256 refundedAfterReclaim = RECLAIMER.balance;
    vm.warp(100);
    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector, SameChainState.BothCommitted, SameChainState.Reclaimed
      )
    );
    same.selectClaim(reclaimedTerms, reclaimedLock, SECRET);
    assertEq(RECLAIMER.balance, refundedAfterReclaim);
    assertTrue(SwapHTLC(payable(same.htlcOf(reclaimedTerms, true, reclaimedLock))).released());
    assertTrue(SwapHTLC(payable(same.htlcOf(reclaimedTerms, false, reclaimedLock))).released());
  }

  function test_authorizationMatrixCompletesDirectDirectWalletWalletAndMixedSwaps() public {
    _completeMatrixSwap(AuthorizationMode.RegisteredDirect, AuthorizationMode.RegisteredDirect, 1000);
    _completeMatrixSwap(AuthorizationMode.QuipWallet, AuthorizationMode.QuipWallet, 1100);
    _completeMatrixSwap(AuthorizationMode.QuipWallet, AuthorizationMode.RegisteredDirect, 1200);
  }

  function test_specificDelegatePrincipalAndBrokerCompleteSwapsWithPrincipalSignature() public {
    (ProtocolTerms memory principalTerms, bytes32 principalLock, ERC20Mock principalToken, ERC20Mock bobToken) =
      _matrixTerms(AuthorizationMode.RegisteredDirect, AuthorizationMode.RegisteredDirect, 1300);
    principalTerms.partySide.delegationPolicy = DelegationPolicy.SpecificDelegate;
    principalTerms.partySide.delegate = broker;
    principalTerms.partySide.delegateKeyVersion = 1;
    principalLock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(principalTerms), SECRET);
    _fundMatrix(principalTerms, principalToken, bobToken);
    _matrixCommit(principalTerms, true, principalLock, 1301, alice, aliceKey);
    _matrixCommit(principalTerms, false, principalLock, 1302, bob, bobKey);
    vm.prank(RELAYER);
    _claimSame(principalTerms, principalLock);
    _assertMatrixFinal(principalTerms, principalLock, principalToken, bobToken);

    (ProtocolTerms memory brokerTerms, bytes32 brokerLock, ERC20Mock brokerToken, ERC20Mock secondBobToken) =
      _matrixTerms(AuthorizationMode.RegisteredDirect, AuthorizationMode.RegisteredDirect, 1400);
    brokerTerms.partySide.delegationPolicy = DelegationPolicy.SpecificDelegate;
    brokerTerms.partySide.delegate = broker;
    brokerTerms.partySide.delegateKeyVersion = 1;
    brokerLock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(brokerTerms), SECRET);
    _fundMatrix(brokerTerms, brokerToken, secondBobToken);

    CommitAuthorizationRequest memory brokerRequest = _request(address(same), brokerTerms, true, brokerLock, 1401);
    vm.expectRevert(DirectAuthorization.InvalidPQAuthorization.selector);
    vm.prank(broker);
    gateway.authorizeCommit(brokerRequest, _signature(brokerRequest, address(gateway), brokerKey));
    assertEq(brokerToken.balanceOf(alice), 10 ether);
    assertEq(brokerToken.balanceOf(address(same)), 0);

    _matrixCommit(brokerTerms, true, brokerLock, 1401, broker, aliceKey);
    assertEq(brokerToken.balanceOf(alice), 0);
    assertEq(brokerToken.balanceOf(broker), 0);
    assertEq(brokerToken.balanceOf(same.htlcOf(brokerTerms, true, brokerLock)), 10 ether);
    _matrixCommit(brokerTerms, false, brokerLock, 1402, bob, bobKey);
    vm.prank(RELAYER);
    _claimSame(brokerTerms, brokerLock);
    _assertMatrixFinal(brokerTerms, brokerLock, brokerToken, secondBobToken);
  }

  function test_permissionlessRelayerCompletesSwapWhilePrincipalsFundAndTermsFixPayouts() public {
    (ProtocolTerms memory terms, bytes32 lock, ERC20Mock aliceToken, ERC20Mock bobToken) =
      _matrixTerms(AuthorizationMode.RegisteredDirect, AuthorizationMode.RegisteredDirect, 1500);
    terms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    terms.counterpartySide.delegationPolicy = DelegationPolicy.Permissionless;
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    _fundMatrix(terms, aliceToken, bobToken);

    _matrixCommit(terms, true, lock, 1501, RELAYER, aliceKey);
    _matrixCommit(terms, false, lock, 1502, RELAYER, bobKey);
    assertEq(aliceToken.balanceOf(RELAYER), 0);
    assertEq(bobToken.balanceOf(RELAYER), 0);
    assertEq(aliceToken.balanceOf(same.htlcOf(terms, true, lock)), 10 ether);
    assertEq(bobToken.balanceOf(same.htlcOf(terms, false, lock)), 20 ether);

    vm.prank(RELAYER);
    _claimSame(terms, lock);
    _assertMatrixFinal(terms, lock, aliceToken, bobToken);
    assertEq(aliceToken.balanceOf(RELAYER), 0);
    assertEq(bobToken.balanceOf(RELAYER), 0);
  }

  function test_notAllowedRejectsNonprincipalOnDirectAndWalletBeforeAllEffects() public {
    (ProtocolTerms memory terms, bytes32 lock, ERC20Mock aliceToken, ERC20Mock bobToken) =
      _matrixTerms(AuthorizationMode.RegisteredDirect, AuthorizationMode.QuipWallet, 1600);
    _fundMatrix(terms, aliceToken, bobToken);

    CommitAuthorizationRequest memory aliceRequest = _request(address(same), terms, true, lock, 1601);
    vm.expectRevert(AuthorizationSubmitter.InvalidTransportSubmitter.selector);
    vm.prank(RELAYER);
    gateway.authorizeCommit(aliceRequest, _signature(aliceRequest, address(gateway), aliceKey));
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Unused));
    assertEq(aliceToken.balanceOf(alice), 10 ether);
    assertEq(aliceToken.balanceOf(address(same)), 0);
    assertEq(same.predictHTLC(terms, true, lock).code.length, 0);

    // The exact same authorization nonce succeeds for the principal, proving
    // the rejected transport consumed neither wrapper nor nonce state.
    _matrixCommit(terms, true, lock, 1601, alice, aliceKey);

    CommitAuthorizationRequest memory bobRequest = _request(address(same), terms, false, lock, 1602);
    bytes memory bobSignature = _signature(bobRequest, address(bobWallet), bobWalletKey);
    vm.expectRevert(AuthorizationSubmitter.InvalidTransportSubmitter.selector);
    vm.prank(RELAYER);
    bobWallet.authorizeCommit(bobRequest, bobSignature);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.PartyCommitted));
    assertEq(bobToken.balanceOf(address(bobWallet)), 20 ether);
    assertEq(bobToken.balanceOf(address(same)), 0);
    assertEq(same.predictHTLC(terms, false, lock).code.length, 0);

    _matrixCommit(terms, false, lock, 1602, address(bobWallet), bobWalletKey);
    vm.prank(RELAYER);
    _claimSame(terms, lock);
    _assertMatrixFinal(terms, lock, aliceToken, bobToken);
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
    _claimSame(terms, lock);

    assertEq(token.balanceOf(RECIPIENT), 10 ether);
    assertEq(bobToken.balanceOf(RECIPIENT), 20 ether);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Claimed));
  }

  function _completeMatrixSwap(
    AuthorizationMode partyMode,
    AuthorizationMode counterpartyMode,
    uint256 nonce
  ) internal {
    (ProtocolTerms memory terms, bytes32 lock, ERC20Mock partyToken, ERC20Mock counterpartyToken) =
      _matrixTerms(partyMode, counterpartyMode, nonce);
    _fundMatrix(terms, partyToken, counterpartyToken);
    _matrixCommit(
      terms,
      true,
      lock,
      nonce + 1,
      terms.partySide.principal,
      partyMode == AuthorizationMode.QuipWallet ? walletKey : aliceKey
    );
    _matrixCommit(
      terms,
      false,
      lock,
      nonce + 2,
      terms.counterpartySide.principal,
      counterpartyMode == AuthorizationMode.QuipWallet ? bobWalletKey : bobKey
    );
    vm.prank(RELAYER);
    _claimSame(terms, lock);
    _assertMatrixFinal(terms, lock, partyToken, counterpartyToken);
  }

  function _matrixTerms(
    AuthorizationMode partyMode,
    AuthorizationMode counterpartyMode,
    uint256 nonce
  ) internal returns (ProtocolTerms memory terms, bytes32 lock, ERC20Mock partyToken, ERC20Mock counterpartyToken) {
    partyToken = new ERC20Mock('Matrix Party', 'MPA', 18);
    counterpartyToken = new ERC20Mock('Matrix Counterparty', 'MCO', 18);
    address partyPrincipal = partyMode == AuthorizationMode.QuipWallet ? address(wallet) : alice;
    address counterpartyPrincipal = counterpartyMode == AuthorizationMode.QuipWallet ? address(bobWallet) : bob;
    terms.partySide = _side(
      partyPrincipal,
      partyMode,
      partyMode == AuthorizationMode.QuipWallet ? 0 : 1,
      _oneAsset(AssetType.ERC20, address(partyToken), 0, 10 ether),
      nonce
    );
    terms.counterpartySide = _side(
      counterpartyPrincipal,
      counterpartyMode,
      counterpartyMode == AuthorizationMode.QuipWallet ? 0 : 1,
      _oneAsset(AssetType.ERC20, address(counterpartyToken), 0, 20 ether),
      nonce + 1
    );
    terms.partySide.commitmentDeadline = 200;
    terms.partySide.claimDeadline = 300;
    terms.partySide.reclaimRelease = 500;
    terms.counterpartySide.commitmentDeadline = 220;
    terms.counterpartySide.claimDeadline = 320;
    terms.counterpartySide.reclaimRelease = 520;
    terms.partySide.recipient = bob;
    terms.counterpartySide.recipient = alice;
    terms.partySide.reclaimRecipient = partyPrincipal;
    terms.counterpartySide.reclaimRecipient = counterpartyPrincipal;
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
  }

  function _fundMatrix(ProtocolTerms memory terms, ERC20Mock partyToken, ERC20Mock counterpartyToken) internal {
    partyToken.mint(terms.partySide.principal, 10 ether);
    counterpartyToken.mint(terms.counterpartySide.principal, 20 ether);
    if (terms.partySide.authorizationMode == AuthorizationMode.QuipWallet) {
      wallet.execute(address(partyToken), 0, abi.encodeCall(partyToken.approve, (address(same), 10 ether)));
    } else {
      vm.prank(alice);
      partyToken.approve(address(same), 10 ether);
    }
    if (terms.counterpartySide.authorizationMode == AuthorizationMode.QuipWallet) {
      vm.prank(bob);
      bobWallet.execute(
        address(counterpartyToken), 0, abi.encodeCall(counterpartyToken.approve, (address(same), 20 ether))
      );
    } else {
      vm.prank(bob);
      counterpartyToken.approve(address(same), 20 ether);
    }
  }

  function _matrixCommit(
    ProtocolTerms memory terms,
    bool party,
    bytes32 lock,
    uint256 nonce,
    address caller,
    bytes memory principalKey
  ) internal {
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    address boundary = side.authorizationMode == AuthorizationMode.QuipWallet ? side.principal : address(gateway);
    CommitAuthorizationRequest memory request = _request(address(same), terms, party, lock, nonce);
    bytes memory signature = _signature(request, boundary, principalKey);
    if (side.authorizationMode == AuthorizationMode.RegisteredDirect) {
      vm.prank(caller);
      gateway.authorizeCommit(request, signature);
    } else if (caller == side.principal) {
      if (side.principal == address(wallet)) {
        wallet.execute(address(wallet), 0, abi.encodeCall(wallet.authorizeCommit, (request, signature)));
      } else {
        vm.prank(bob);
        bobWallet.execute(address(bobWallet), 0, abi.encodeCall(bobWallet.authorizeCommit, (request, signature)));
      }
    } else {
      vm.prank(caller);
      QuipWallet(payable(side.principal)).authorizeCommit(request, signature);
    }
  }

  function _assertMatrixFinal(
    ProtocolTerms memory terms,
    bytes32 lock,
    ERC20Mock partyToken,
    ERC20Mock counterpartyToken
  ) internal view {
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Claimed));
    assertEq(partyToken.balanceOf(terms.partySide.principal), 0);
    assertEq(counterpartyToken.balanceOf(terms.counterpartySide.principal), 0);
    assertEq(partyToken.balanceOf(terms.partySide.recipient), 10 ether);
    assertEq(counterpartyToken.balanceOf(terms.counterpartySide.recipient), 20 ether);
    assertEq(partyToken.balanceOf(address(same)), 0);
    assertEq(counterpartyToken.balanceOf(address(same)), 0);
    address partyHTLC = same.htlcOf(terms, true, lock);
    address counterpartyHTLC = same.htlcOf(terms, false, lock);
    assertEq(partyToken.balanceOf(partyHTLC), 0);
    assertEq(counterpartyToken.balanceOf(counterpartyHTLC), 0);
    assertTrue(SwapHTLC(payable(partyHTLC)).released());
    assertTrue(SwapHTLC(payable(counterpartyHTLC)).released());
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

  function _claimSame(ProtocolTerms memory terms, bytes32 lock) internal {
    same.selectClaim(terms, lock, SECRET);
    same.executeSettlement(terms, lock, true, terms.partySide.assets.length);
    same.executeSettlement(terms, lock, false, terms.counterpartySide.assets.length);
  }

  function _reclaimSameBoth(ProtocolTerms memory terms, bytes32 lock) internal {
    same.selectReclaim(terms, lock);
    same.executeSettlement(terms, lock, true, terms.partySide.assets.length);
    same.executeSettlement(terms, lock, false, terms.counterpartySide.assets.length);
  }

  function _reclaimSameParty(ProtocolTerms memory terms, bytes32 lock) internal {
    same.selectReclaim(terms, lock);
    same.executeSettlement(terms, lock, true, terms.partySide.assets.length);
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
    if (progressionSecret != bytes32(0) || ProtocolHashing.mode(terms) == WrapperMode.SameChain) {
      request.bobCommitSecret = progressionSecret;
    }
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
    terms.counterpartySide.commitLock =
      ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), BOB_COMMIT_SECRET);
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
    if (ProtocolHashing.mode(terms) == WrapperMode.CrossChain) request.bobCommitSecret = BOB_COMMIT_SECRET;
    request.expiry = 190;
  }

  function _signature(
    CommitAuthorizationRequest memory request,
    address boundary,
    bytes memory key
  ) internal view returns (bytes memory) {
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
    if (boundary == address(wallet)) payload = wallet.commitAuthorizationDigest(payload);
    else if (boundary == address(bobWallet)) payload = bobWallet.commitAuthorizationDigest(payload);
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
    return abi.encodePacked(address(verifier), keccak256(bytes(label)));
  }

  function _pqSig(bytes memory keyedVerifier, bytes32 digest) internal pure returns (bytes memory) {
    bytes memory key = new bytes(keyedVerifier.length - 20);
    for (uint256 i; i < key.length; ++i) {
      key[i] = keyedVerifier[i + 20];
    }
    return abi.encode(key, digest);
  }
}
