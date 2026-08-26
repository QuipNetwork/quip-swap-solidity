// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ISwapHTLC} from '../../src/interfaces/ISwapHTLC.sol';
import {ProtocolHashing} from '../../src/protocol/ProtocolHashing.sol';
import {
  Asset,
  AssetType,
  AuthorizationMode,
  DelegationPolicy,
  SideTag,
  SideTerms
} from '../../src/protocol/ProtocolTypes.sol';
import {SwapHTLC} from '../../src/protocol/SwapHTLC.sol';
import {ERC1155Mock} from '../mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';
import {Test} from 'forge-std-1.14.0/Test.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';

contract SwapHTLCTest is Test {
  bytes32 internal constant TRADE = keccak256('trade');
  bytes32 internal constant LOCK = keccak256('lock');
  address internal constant RECIPIENT = address(0xCAFE);
  address internal constant RECLAIMER = address(0xD00D);
  address internal constant STRANGER = address(0xBAD);

  SwapHTLC internal implementation;
  ERC20Mock internal token;
  ERC721Mock internal nft;
  ERC1155Mock internal multiToken;

  function setUp() public {
    implementation = new SwapHTLC();
    token = new ERC20Mock('Token', 'TOK', 18);
    nft = new ERC721Mock('NFT', 'NFT');
    multiToken = new ERC1155Mock('');
    vm.deal(address(this), 10 ether);
  }

  function test_implementationAndUninitializedCloneCannotBeUsed() public {
    SideTerms memory sideTerms = _nativeTerms(1 ether);
    vm.expectRevert(ISwapHTLC.AlreadyInitialized.selector);
    implementation.initialize{value: 1 ether}(TRADE, LOCK, SideTag.Party, sideTerms);

    SwapHTLC htlc = _clone();
    vm.expectRevert(ISwapHTLC.NotInitialized.selector);
    htlc.confirmFunding(sideTerms);
    vm.expectRevert(ISwapHTLC.NotInitialized.selector);
    htlc.release(sideTerms, RECIPIENT);
  }

  function test_initializeBindsControllerIdentityAndExactNativeValue() public {
    SwapHTLC htlc = _clone();
    SideTerms memory sideTerms = _nativeTerms(1 ether);

    vm.expectRevert(ISwapHTLC.IncorrectNativeAmount.selector);
    htlc.initialize(TRADE, LOCK, SideTag.Counterparty, sideTerms);

    htlc.initialize{value: 1 ether}(TRADE, LOCK, SideTag.Counterparty, sideTerms);
    assertEq(htlc.controller(), address(this));
    assertEq(htlc.tradeId(), TRADE);
    assertEq(htlc.lock(), LOCK);
    assertEq(uint8(htlc.side()), uint8(SideTag.Counterparty));
    assertEq(htlc.sideTermsHash(), ProtocolHashing.sideTermsHash(sideTerms));
    assertEq(address(htlc).balance, 1 ether);

    vm.expectRevert(ISwapHTLC.AlreadyInitialized.selector);
    htlc.initialize{value: 1 ether}(TRADE, LOCK, SideTag.Counterparty, sideTerms);
  }

  function test_initializeRejectsAnHTLCAsEitherPayoutRecipient() public {
    SwapHTLC htlc = _clone();
    SideTerms memory sideTerms = _nativeTerms(1 ether);
    sideTerms.recipient = address(htlc);
    vm.expectRevert(ISwapHTLC.InvalidRecipient.selector);
    htlc.initialize{value: 1 ether}(TRADE, LOCK, SideTag.Party, sideTerms);

    sideTerms.recipient = RECIPIENT;
    sideTerms.reclaimRecipient = address(htlc);
    vm.expectRevert(ISwapHTLC.InvalidRecipient.selector);
    htlc.initialize{value: 1 ether}(TRADE, LOCK, SideTag.Party, sideTerms);
  }

  function test_confirmFundingRequiresControllerBoundTermsAndCompleteAssets() public {
    SwapHTLC htlc = _clone();
    SideTerms memory sideTerms = _erc20Terms(10 ether);
    htlc.initialize(TRADE, LOCK, SideTag.Party, sideTerms);

    vm.prank(STRANGER);
    vm.expectRevert(ISwapHTLC.UnauthorizedController.selector);
    htlc.confirmFunding(sideTerms);

    SideTerms memory changedTerms = _erc20Terms(10 ether);
    changedTerms.recipient = STRANGER;
    vm.expectRevert(ISwapHTLC.SideTermsMismatch.selector);
    htlc.confirmFunding(changedTerms);

    vm.expectRevert(ISwapHTLC.InsufficientAssetBalance.selector);
    htlc.confirmFunding(sideTerms);

    token.mint(address(htlc), 10 ether);
    htlc.confirmFunding(sideTerms);
    assertTrue(htlc.funded());

    vm.expectRevert(ISwapHTLC.InvalidFundingState.selector);
    htlc.confirmFunding(sideTerms);
  }

  function test_releaseTransfersMixedBundleExactlyOnceToTermsRecipient() public {
    SwapHTLC htlc = _clone();
    SideTerms memory sideTerms = _mixedTerms();
    htlc.initialize{value: 1 ether}(TRADE, LOCK, SideTag.Party, sideTerms);
    token.mint(address(htlc), 10 ether);
    nft.mint(address(htlc), 7);
    multiToken.mint(address(htlc), 9, 3, '');
    htlc.confirmFunding(sideTerms);

    vm.prank(STRANGER);
    vm.expectRevert(ISwapHTLC.UnauthorizedController.selector);
    htlc.release(sideTerms, RECIPIENT);
    vm.expectRevert(ISwapHTLC.InvalidRecipient.selector);
    htlc.release(sideTerms, STRANGER);

    htlc.release(sideTerms, RECIPIENT);
    assertTrue(htlc.released());
    assertEq(RECIPIENT.balance, 1 ether);
    assertEq(token.balanceOf(RECIPIENT), 10 ether);
    assertEq(nft.ownerOf(7), RECIPIENT);
    assertEq(multiToken.balanceOf(RECIPIENT, 9), 3);

    vm.expectRevert(ISwapHTLC.AlreadyReleased.selector);
    htlc.release(sideTerms, RECLAIMER);
  }

  function test_releaseCanSelectTheTermsFixedReclaimRecipient() public {
    SwapHTLC htlc = _clone();
    SideTerms memory sideTerms = _nativeTerms(1 ether);
    htlc.initialize{value: 1 ether}(TRADE, LOCK, SideTag.Party, sideTerms);
    htlc.confirmFunding(sideTerms);

    htlc.release(sideTerms, RECLAIMER);
    assertEq(RECLAIMER.balance, 1 ether);
    assertTrue(htlc.released());
  }

  function test_releaseBeforeFundingAndWithChangedTermsRevertsWithoutEffects() public {
    SwapHTLC htlc = _clone();
    SideTerms memory sideTerms = _nativeTerms(1 ether);
    htlc.initialize{value: 1 ether}(TRADE, LOCK, SideTag.Party, sideTerms);

    vm.expectRevert(ISwapHTLC.InvalidFundingState.selector);
    htlc.release(sideTerms, RECIPIENT);
    htlc.confirmFunding(sideTerms);

    SideTerms memory changedTerms = sideTerms;
    changedTerms.sideNonce = keccak256('changed');
    vm.expectRevert(ISwapHTLC.SideTermsMismatch.selector);
    htlc.release(changedTerms, RECIPIENT);
    assertFalse(htlc.released());
    assertEq(address(htlc).balance, 1 ether);
  }

  function _clone() internal returns (SwapHTLC) {
    return SwapHTLC(payable(LibClone.clone(address(implementation))));
  }

  function _nativeTerms(uint256 amount) internal view returns (SideTerms memory sideTerms) {
    sideTerms = _baseTerms();
    sideTerms.assets = new Asset[](1);
    sideTerms.assets[0] = Asset(AssetType.Native, address(0), 0, amount);
  }

  function _erc20Terms(uint256 amount) internal view returns (SideTerms memory sideTerms) {
    sideTerms = _baseTerms();
    sideTerms.assets = new Asset[](1);
    sideTerms.assets[0] = Asset(AssetType.ERC20, address(token), 0, amount);
  }

  function _mixedTerms() internal view returns (SideTerms memory sideTerms) {
    sideTerms = _baseTerms();
    sideTerms.assets = new Asset[](4);
    sideTerms.assets[0] = Asset(AssetType.Native, address(0), 0, 1 ether);
    sideTerms.assets[1] = Asset(AssetType.ERC20, address(token), 0, 10 ether);
    sideTerms.assets[2] = Asset(AssetType.ERC721, address(nft), 7, 1);
    sideTerms.assets[3] = Asset(AssetType.ERC1155, address(multiToken), 9, 3);
  }

  function _baseTerms() internal view returns (SideTerms memory sideTerms) {
    sideTerms = SideTerms({
      chainId: block.chainid,
      assets: new Asset[](0),
      principal: address(this),
      authorizationMode: AuthorizationMode.RegisteredDirect,
      principalKeyVersion: 1,
      reclaimRecipient: RECLAIMER,
      recipient: RECIPIENT,
      commitmentDeadline: 200,
      claimDeadline: 300,
      reclaimRelease: 400,
      commitLock: bytes32(0),
      delegationPolicy: DelegationPolicy.NotAllowed,
      delegate: address(0),
      delegateKeyVersion: 0,
      sideNonce: keccak256('side-nonce')
    });
  }
}
