// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Quip} from '../../../src/Quip.sol';
import {QuipPortal} from '../../../src/QuipPortal.sol';
import {PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {ERC20Mock} from '../../mocks/ERC20Mock.sol';
import {QuipPortalHandler} from './Handler.t.sol';

/// @title QuipPortal Invariant Tests
/// @dev Invariant tests for QuipPortal
contract QuipPortalInvariantTest is Test {
  QuipPortal public portal;
  Quip public quipImpl;
  ERC20Mock public mockERC20;
  QuipPortalHandler public handler;

  address public ADMIN = makeAddr('admin');
  address[] public actors;

  uint256 public constant MAX_FEE = 1 ether;
  uint256 public constant CREATION_FEE = 0.01 ether;

  function setUp() public {
    // deploy contracts
    quipImpl = new Quip();
    portal = new QuipPortal(ADMIN, address(quipImpl), MAX_FEE, CREATION_FEE);
    mockERC20 = new ERC20Mock('Mock', 'MCK', 18);

    // setup actors
    actors.push(makeAddr('alice'));
    actors.push(makeAddr('bob'));
    actors.push(makeAddr('charlie'));

    // fund actors
    for (uint256 i = 0; i < actors.length; i++) {
      vm.deal(actors[i], 1000 ether);
      mockERC20.mint(actors[i], 1_000_000 ether);
    }

    // deploy handler
    handler = new QuipPortalHandler(portal, mockERC20, ADMIN, actors);

    // target the handler
    targetContract(address(handler));
  }

  // ============ Invariants ============

  /// @notice Accumulated fees should never exceed the portal's balance
  function invariant_accumulatedFeesNeverExceedBalance() public view {
    assertLe(portal.accumulatedFees(), address(portal).balance);
  }

  /// @notice Creation fee should never exceed MAX_FEE
  function invariant_creationFeeNeverExceedsMax() public view {
    assertLe(portal.creationFee(), portal.MAX_FEE());
  }

  /// @notice Used pqOwners should not be in Unused state (they're either Free or Spent)
  function invariant_usedPqOwnersNotUnused() public view {
    uint256 usedPqOwnerHashesCount = handler.getUsedPqOwnerHashesCount();
    for (uint256 i = 0; i < usedPqOwnerHashesCount; i++) {
      bytes32 pqOwnerHash = handler.ghost_usedPqOwnerHashes(i);
      assertTrue(portal.pqOwnerState(pqOwnerHash) != PqOwnerState.Unused);
    }
  }

  /// @notice Ghost fees should match accumulated fees (before withdrawals)
  function invariant_ghostFeesConsistency() public view {
    // note: This only holds if no withdrawals have occurred
    // the handler tracks total fees collected, portal tracks current accumulated
    assertLe(portal.accumulatedFees(), handler.ghost_totalFeesCollected());
  }

  /// @notice Admin address should never be zero
  function invariant_adminNeverZero() public view {
    assertNotEq(portal.admin(), address(0));
  }

  /// @notice VERSION should be immutable
  function invariant_versionIsConstant() public view {
    assertEq(portal.VERSION(), 1);
  }

  /// @notice MAX_FEE should be immutable
  function invariant_maxFeeIsConstant() public view {
    assertEq(portal.MAX_FEE(), MAX_FEE);
  }
}
