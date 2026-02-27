// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Quip} from '../../../src/Quip.sol';
import {QuipPortal} from '../../../src/QuipPortal.sol';
import {QuipHandler} from './Handler.t.sol';

/// @title Quip Invariant Tests
/// @dev Invariant tests for Quip
contract QuipInvariantTest is Test {
  QuipPortal public portal;
  Quip public quipImpl;
  QuipHandler public handler;

  address public ADMIN = makeAddr('admin');
  address[] public actors;

  uint256 public constant MAX_FEE = 1 ether;
  uint256 public constant CREATION_FEE = 0.01 ether;

  function setUp() public {
    // Deploy contracts
    quipImpl = new Quip();
    portal = new QuipPortal(ADMIN, address(quipImpl), MAX_FEE, CREATION_FEE);

    // Setup actors
    actors.push(makeAddr('alice'));
    actors.push(makeAddr('bob'));
    actors.push(makeAddr('charlie'));

    // Fund actors
    for (uint256 i = 0; i < actors.length; i++) {
      vm.deal(actors[i], 1000 ether);
    }

    // Deploy handler
    handler = new QuipHandler(portal, quipImpl, actors);

    // Target the handler
    targetContract(address(handler));
  }

  // ============ Invariants ============

  /// @notice PqOwnerHash should be immutable after initialization
  function invariant_pqOwnerHashImmutableAfterInit() public view {
    uint256 quipCount = handler.getDeployedQuipsCount();
    for (uint256 i = 0; i < quipCount; i++) {
      Quip quip = handler.deployedQuips(i);
      // PqOwnerHash should be set (not zero for coupled quips)
      assertNotEq(quip.pqOwnerHash(), bytes32(0));
    }
  }

  /// @notice VERSION should be constant across all quips
  function invariant_versionConstant() public view {
    uint256 quipCount = handler.getDeployedQuipsCount();
    for (uint256 i = 0; i < quipCount; i++) {
      Quip quip = handler.deployedQuips(i);
      assertEq(quip.VERSION(), 1);
    }
  }

  /// @notice Coupled quips should have INIT_UNCOUPLED as false
  function invariant_coupledQuipsInitUncoupledFalse() public view {
    uint256 quipCount = handler.getDeployedQuipsCount();
    for (uint256 i = 0; i < quipCount; i++) {
      Quip quip = handler.deployedQuips(i);
      assertFalse(quip.INIT_UNCOUPLED());
    }
  }

  /// @notice Claims + Reclaims should not exceed deployments
  function invariant_operationsNotExceedDeployments() public view {
    uint256 totalOperations = handler.ghost_claimedCount() + handler.ghost_reclaimedCount();
    assertLe(totalOperations, handler.getDeployedQuipsCount());
  }
}
