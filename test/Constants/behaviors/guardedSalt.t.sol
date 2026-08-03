// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Constants} from '../../../script/Constants.sol';
import {SaltRef} from '../../utils/SaltRef.sol';
import {ConstantsTest} from '../Constants.t.sol';

/// @title Constants guardedSalt Tests
/// @dev Tests for the local mirror of CreateX's `_guard`.
///
///      `Constants.guardedSalt()` re-implements one branch of CreateX's salt
///      guarding off-chain, so the deploy scripts can predict the address with
///      no RPC. A mirror that drifts from the real factory would predict an
///      address the factory never deploys to — which is why the deploy script
///      also cross-checks against `computeCreate3Address` on-chain, and why the
///      fork test in ../integration/ exercises the real bytecode.
///
///      These tests pin the formula three ways: against the live chain, against
///      an independent reference derivation, and against the permissionless
///      branch it must never collide with.
contract Constants_guardedSalt is ConstantsTest {
  // ============ Known-answer ============

  function test_guardedSalt_matchesLiveGuardedSalt() public pure {
    assertEq(Constants.guardedSalt(), LIVE_GUARDED_SALT, 'guarded salt no longer matches the live deployment');
  }

  function test_guardedSalt_matchesCreateXPermissionedFormula() public pure {
    assertEq(
      Constants.guardedSalt(),
      SaltRef.permissionedGuard(Constants.DEPLOYER, Constants.omnibusSalt()),
      'guard mirror disagrees with the reference MsgSender formula'
    );
  }

  /// @dev CreateX hashes `abi.encode(sender, salt)`; the library writes it as
  ///      `abi.encodePacked(bytes32(uint256(uint160(sender))), salt)`. Those are
  ///      the same 64 bytes — assert it rather than trusting the reasoning,
  ///      since the widening is easy to get wrong.
  function test_guardedSalt_packedWideningEqualsAbiEncode() public pure {
    assertEq(
      Constants.guardedSalt(),
      keccak256(abi.encode(Constants.DEPLOYER, Constants.omnibusSalt())),
      'packed widening is not equivalent to abi.encode'
    );
  }

  // ============ Anti-squat: the permissioned branch must not collide ============

  /// @dev The whole point of the permissioned salt. Anyone else passing OUR raw
  ///      salt to CreateX fails the sender-prefix match and falls to
  ///      `keccak256(abi.encode(salt))`. If those two guards ever produced the
  ///      same value, the address would be claimable by anyone.
  function test_guardedSalt_differsFromPermissionlessGuard() public pure {
    assertTrue(
      Constants.guardedSalt() != SaltRef.permissionlessGuard(Constants.omnibusSalt()),
      'permissioned and permissionless guards collide: the address is squattable'
    );
  }

  /// @dev The 0x01 flag byte would mix block.chainid into the guard and break
  ///      chain-invariance. Assert we are not accidentally on that branch.
  function test_guardedSalt_differsFromChainScopedGuard() public view {
    assertTrue(
      Constants.guardedSalt() != SaltRef.chainScopedGuard(Constants.DEPLOYER, Constants.omnibusSalt()),
      'guarded salt matches the chain-scoped branch: the address would be per-chain'
    );
  }

  // ============ Fuzz ============

  function testFuzz_guardedSalt_permissionedDiffersFromPermissionless(address deployer, bytes11 entropy) public pure {
    bytes32 salt = SaltRef.rawSalt(deployer, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, entropy);

    assertTrue(
      SaltRef.permissionedGuard(deployer, salt) != SaltRef.permissionlessGuard(salt),
      'permissioned and permissionless guards collide'
    );
  }

  /// @dev Distinct senders must never guard to the same value, or one EOA's salt
  ///      could land on another's address.
  function testFuzz_guardedSalt_distinctSendersGuardDistinctly(address a, address b, bytes11 entropy) public pure {
    vm.assume(a != b);
    bytes32 saltA = SaltRef.rawSalt(a, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, entropy);
    bytes32 saltB = SaltRef.rawSalt(b, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, entropy);

    assertTrue(SaltRef.permissionedGuard(a, saltA) != SaltRef.permissionedGuard(b, saltB), 'guard collision');
  }
}
