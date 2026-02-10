// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Asset, AssetType, QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {IQuipPortal} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortal} from '../../../src/QuipPortal.sol';
import {Quip} from '../../../src/Quip.sol';

/// @title Quip Invariant Handler
/// @dev Handler contract for Quip invariant testing
contract QuipHandler is Test {
  QuipPortal public portal;
  Quip public quipImpl;

  address[] public actors;

  // Track deployed quips
  Quip[] public deployedQuips;
  bytes[] public deployedQuipKeys;

  // Ghost variables
  uint256 public ghost_claimedCount;
  uint256 public ghost_reclaimedCount;

  constructor(QuipPortal _portal, Quip _quipImpl, address[] memory _actors) {
    portal = _portal;
    quipImpl = _quipImpl;
    actors = _actors;
  }

  function deployAndTrackQuip(uint256 seed, uint256 nativeAmount) external {
    address actor = actors[seed % actors.length];
    bytes memory key = abi.encodePacked('key', seed, deployedQuips.length);
    bytes32 lock = keccak256(key);

    if (portal.isLockSpent(lock)) return;

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
    portal.deployCoupledQuip{value: totalRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);

    deployedQuips.push(Quip(payable(quipAddr)));
    deployedQuipKeys.push(key);
  }

  function getDeployedQuipsCount() external view returns (uint256) {
    return deployedQuips.length;
  }

  function _findQuipCreatedAddress(Vm.Log[] memory logs) internal pure returns (address) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.QuipCreated.selector) {
        return address(uint160(uint256(logs[i].topics[1])));
      }
    }
    revert('QuipCreated event not found');
  }
}
