// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../../src/Quip.sol';
import {QuipPortal} from '../../../src/QuipPortal.sol';
import {Asset, AssetType, QuipTerms} from '../../../src/TermsLib.sol';
import {IQuipPortal, PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title Quip Invariant Handler
/// @dev Handler contract for Quip invariant testing
contract QuipHandler is Test {
  QuipPortal public portal;
  Quip public quipImpl;

  address[] public actors;

  // track deployed quips
  Quip[] public deployedQuips;
  bytes32[] public deployedQuipPrivateKeys;

  // ghost variables
  uint256 public ghost_claimedCount;
  uint256 public ghost_reclaimedCount;
  uint256 public ghost_keyIndex;

  constructor(QuipPortal _portal, Quip _quipImpl, address[] memory _actors) {
    portal = _portal;
    quipImpl = _quipImpl;
    actors = _actors;
  }

  function deployAndTrackQuip(uint256 seed, uint256 nativeAmount) external {
    address actor = actors[seed % actors.length];

    // generate unique key pair
    bytes32 privateSeed = keccak256(abi.encodePacked('pqOwner', ghost_keyIndex, seed));
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = WOTSPlus.generateKeyPair(privateSeed);
    bytes32 pqOwnerHash = EfficientHashLib.hash(pqOwner.publicSeed, pqOwner.publicKeyHash);
    ghost_keyIndex++;

    if (portal.pqOwnerState(pqOwnerHash) != PqOwnerState.Unused) return;

    nativeAmount = bound(nativeAmount, 1, 10 ether);

    Asset[] memory partyAssets = new Asset[](1);
    partyAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: nativeAmount});

    Asset[] memory counterpartyAssets = new Asset[](1);
    counterpartyAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 1 ether});

    QuipTerms memory terms = QuipTerms({
      party: actor,
      partyRecipient: actor,
      counterparty: actors[(seed + 1) % actors.length],
      counterpartyRecipient: actors[(seed + 1) % actors.length],
      partyExpiry: uint64(block.timestamp + 1 days),
      counterpartyExpiry: uint64(block.timestamp + 1 days),
      partyAssets: partyAssets,
      counterpartyAssets: counterpartyAssets
    });

    uint256 creationFee = portal.creationFee();
    uint256 totalRequired = creationFee + nativeAmount;

    vm.deal(actor, totalRequired);
    vm.prank(actor);
    vm.recordLogs();
    portal.deployCoupledQuip{value: totalRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);

    deployedQuips.push(Quip(payable(quipAddr)));
    deployedQuipPrivateKeys.push(privateKey);
  }

  function getDeployedQuipsCount() external view returns (uint256) {
    return deployedQuips.length;
  }

  function _findQuipCreatedAddress(Vm.Log[] memory logs) internal pure returns (address) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.QuipCreated.selector) {
        // topics[1] = pqOwnerHash (bytes32 indexed), topics[2] = quip (address indexed)
        return address(uint160(uint256(logs[i].topics[2])));
      }
    }
    revert('QuipCreated event not found');
  }
}
