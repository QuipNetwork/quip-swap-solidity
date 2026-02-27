// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {QuipPortal} from '../../../src/QuipPortal.sol';
import {Asset, AssetType, PartyTerms, QuipTerms} from '../../../src/TermsLib.sol';
import {PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {ERC20Mock} from '../../mocks/ERC20Mock.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title QuipPortal Invariant Handler
/// @dev Handler contract for QuipPortal invariant testing
contract QuipPortalHandler is Test {
  QuipPortal public portal;
  ERC20Mock public mockERC20;

  address public admin;
  address[] public actors;

  // ghost variables for tracking state
  uint256 public ghost_totalFeesCollected;
  uint256 public ghost_deploymentsCount;
  bytes32[] public ghost_usedPqOwnerHashes;
  uint256 public ghost_keyIndex;

  constructor(QuipPortal _portal, ERC20Mock _mockERC20, address _admin, address[] memory _actors) {
    portal = _portal;
    mockERC20 = _mockERC20;
    admin = _admin;
    actors = _actors;
  }

  function deployCoupledQuip(uint256 actorSeed, uint256 lockSeed, uint256 nativeAmount) external {
    address actor = actors[actorSeed % actors.length];

    // generate unique key pair
    bytes32 privateSeed = keccak256(abi.encodePacked('coupled', lockSeed, ghost_keyIndex));
    (WOTSPlus.WinternitzAddress memory pqOwner,) = WOTSPlus.generateKeyPair(privateSeed);
    bytes32 pqOwnerHash = EfficientHashLib.hash(pqOwner.publicSeed, pqOwner.publicKeyHash);
    ghost_keyIndex++;

    // skip if pqOwner already spent
    if (portal.pqOwnerState(pqOwnerHash) != PqOwnerState.Unused) return;

    nativeAmount = bound(nativeAmount, 1, 10 ether);

    Asset[] memory partyAssets = new Asset[](1);
    partyAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: nativeAmount});

    Asset[] memory counterpartyAssets = new Asset[](1);
    counterpartyAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 1 ether});

    QuipTerms memory terms = QuipTerms({
      party: actor,
      partyRecipient: actor,
      counterparty: actors[(actorSeed + 1) % actors.length],
      counterpartyRecipient: actors[(actorSeed + 1) % actors.length],
      partyExpiry: uint64(block.timestamp + 1 days),
      counterpartyExpiry: uint64(block.timestamp + 1 days),
      partyAssets: partyAssets,
      counterpartyAssets: counterpartyAssets
    });

    uint256 creationFee = portal.creationFee();
    uint256 totalRequired = creationFee + nativeAmount;

    vm.deal(actor, totalRequired);
    vm.prank(actor);
    portal.deployCoupledQuip{value: totalRequired}(pqOwner, terms);

    ghost_totalFeesCollected += creationFee;
    ghost_deploymentsCount++;
    ghost_usedPqOwnerHashes.push(pqOwnerHash);
  }

  function deployUncoupledQuip(uint256 actorSeed, uint256 lockSeed) external {
    address actor = actors[actorSeed % actors.length];

    // generate unique key pair
    bytes32 privateSeed = keccak256(abi.encodePacked('uncoupled', lockSeed, ghost_keyIndex));
    (WOTSPlus.WinternitzAddress memory pqOwner,) = WOTSPlus.generateKeyPair(privateSeed);
    bytes32 pqOwnerHash = EfficientHashLib.hash(pqOwner.publicSeed, pqOwner.publicKeyHash);
    ghost_keyIndex++;

    if (portal.pqOwnerState(pqOwnerHash) != PqOwnerState.Unused) return;

    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 1 ether});

    PartyTerms memory terms =
      PartyTerms({signatory: actor, recipient: actor, expiry: uint64(block.timestamp + 1 days), assets: assets});

    uint256 creationFee = portal.creationFee();

    vm.deal(actor, creationFee);
    vm.prank(actor);
    portal.deployUncoupledQuip{value: creationFee}(pqOwner, terms);

    ghost_totalFeesCollected += creationFee;
    ghost_deploymentsCount++;
    ghost_usedPqOwnerHashes.push(pqOwnerHash);
  }

  function withdrawFees(uint256 amount) external {
    uint256 accumulatedFees = portal.accumulatedFees();
    amount = bound(amount, 0, accumulatedFees);

    vm.prank(admin);
    portal.withdrawFees(admin, amount);
  }

  function setCreationFee(uint256 newFee) external {
    newFee = bound(newFee, 0, portal.MAX_FEE());

    vm.prank(admin);
    portal.setCreationFee(newFee);
  }

  function getUsedPqOwnerHashesCount() external view returns (uint256) {
    return ghost_usedPqOwnerHashes.length;
  }
}
