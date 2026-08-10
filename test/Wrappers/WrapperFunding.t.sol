// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetCustody} from '../../src/AssetCustody.sol';
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
import {QuipWalletAuthorizationAdapter} from '../../src/QuipWalletAuthorizationAdapter.sol';
import {SameChainWrapper} from '../../src/SameChainWrapper.sol';
import {Asset, AssetType} from '../../src/TermsLib.sol';
import {TimingPolicyRegistry} from '../../src/TimingPolicyRegistry.sol';
import {ReentrantRecipient} from '../attack/Reentrancy.t.sol';
import {RegisteredCommitTargetHarness} from '../harness/RegisteredCommitTargetHarness.sol';
import {ERC1155Mock} from '../mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';
import {FeeOnTransferERC20Mock} from '../mocks/FeeOnTransferERC20Mock.sol';
import {KeyBoundVerifierMock} from '../mocks/KeyBoundVerifierMock.sol';
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
  CrossChainWrapper internal cross;
  SameChainWrapper internal same;
  QuipWalletAuthorizationAdapter internal wallet;
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
    cross = new CrossChainWrapper(address(gateway), policies);
    same = new SameChainWrapper(address(gateway), policies);
    wallet = new QuipWalletAuthorizationAdapter(address(this), registry, walletKey);
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
  ) internal view returns (SideTerms memory side) {
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
