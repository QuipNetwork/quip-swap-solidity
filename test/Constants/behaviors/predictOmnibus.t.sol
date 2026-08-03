// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Constants} from '../../../script/Constants.sol';
import {SaltRef} from '../../utils/SaltRef.sol';
import {ConstantsTest} from '../Constants.t.sol';

/// @title Constants predictOmnibus Tests
/// @dev Tests for the full CREATE3 derivation, and the registry lock.
///
///      `predictOmnibus()` composes three things that are each tested above or
///      here: the raw salt layout, CreateX's guard, and solady's CREATE3 proxy
///      math. The known-answer test below is deliberately GUARD-INDEPENDENT —
///      it feeds the live guarded salt straight into `SaltRef.create3`, which
///      applies no policy at all. That keeps the anchor to reality valid even
///      if the guard mode is ever changed.
contract Constants_predictOmnibus is ConstantsTest {
  // ============ Known-answer ============

  function test_predictOmnibus_matchesLiveBaseSepoliaAddress() public pure {
    assertEq(Constants.predictOmnibus(), LIVE_OMNIBUS, 'predicted address no longer matches the live deployment');
  }

  /// @dev Guard-independent: the CREATE2-proxy + nonce-1 math alone must
  ///      reproduce a real on-chain deployment from its guarded salt.
  function test_predictOmnibus_referenceCreate3ReproducesLiveDeployment() public pure {
    assertEq(SaltRef.proxyAddress(LIVE_GUARDED_SALT, Constants.CREATEX), LIVE_PROXY, 'CREATE2 proxy address mismatch');
    assertEq(SaltRef.create3(LIVE_GUARDED_SALT, Constants.CREATEX), LIVE_OMNIBUS, 'CREATE3 child address mismatch');
  }

  /// @dev The library's whole pipeline against the independent reference's.
  function test_predictOmnibus_matchesReferenceDerivation() public pure {
    bytes32 salt =
      SaltRef.rawSalt(Constants.DEPLOYER, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, Constants.OMNIBUS_SALT_ENTROPY);

    assertEq(
      Constants.predictOmnibus(),
      SaltRef.create3(SaltRef.permissionedGuard(Constants.DEPLOYER, salt), Constants.CREATEX),
      'solady-based prediction diverges from the longhand reference'
    );
  }

  // ============ Registry lock (docs ↔ code) ============

  /// @dev `sdk/src/address.json` is what `sdk/src/deployments.ts` ships to every
  ///      SDK consumer. `make verify-omnibus` checks this too, but only when an
  ///      operator remembers to run it — this is the copy that runs in CI.
  function test_predictOmnibus_matchesSdkAddressJson() public view {
    address fromJson =
      vm.parseJsonAddress(vm.readFile(string.concat(vm.projectRoot(), '/sdk/src/address.json')), '.omnibusAddress');

    assertEq(fromJson, Constants.predictOmnibus(), 'sdk/src/address.json is out of sync with the predicted address');
  }

  // ============ Anti-squat ============

  /// @dev Where our salt lands in a stranger's hands. Not merely "somewhere
  ///      else": CreateX's permissionless branch is deterministic, so the squat
  ///      target is exactly predictable — and must not be ours.
  function test_predictOmnibus_differsFromPermissionlessAddress() public pure {
    address squatted = SaltRef.create3(SaltRef.permissionlessGuard(Constants.omnibusSalt()), Constants.CREATEX);

    assertTrue(squatted != Constants.predictOmnibus(), 'our salt in a foreign caller\'s hands reaches OUR address');
  }

  // ============ Fuzz ============

  /// @dev The property that makes a wrong signer SILENT rather than colliding:
  ///      it deploys successfully, just somewhere else. That is precisely why
  ///      DEPLOYER is compiled in and the deploy script gates on it — a
  ///      prediction derived from the live signer would follow the mistake and
  ///      every post-deploy equality check would still pass.
  function testFuzz_predictOmnibus_distinctDeployersGiveDistinctAddresses(address a, address b) public pure {
    vm.assume(a != b);

    address addrA = SaltRef.create3(
      SaltRef.permissionedGuard(
        a, SaltRef.rawSalt(a, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, Constants.OMNIBUS_SALT_ENTROPY)
      ),
      Constants.CREATEX
    );
    address addrB = SaltRef.create3(
      SaltRef.permissionedGuard(
        b, SaltRef.rawSalt(b, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, Constants.OMNIBUS_SALT_ENTROPY)
      ),
      Constants.CREATEX
    );

    assertTrue(addrA != addrB, 'two different deployers reach the same address');
  }

  /// @dev Bumping the entropy label must always move the address — that is the
  ///      documented recovery path for a burned or mistaken salt.
  function testFuzz_predictOmnibus_distinctEntropyGivesDistinctAddresses(bytes11 e1, bytes11 e2) public pure {
    vm.assume(e1 != e2);

    address addr1 = SaltRef.create3(
      SaltRef.permissionedGuard(
        Constants.DEPLOYER, SaltRef.rawSalt(Constants.DEPLOYER, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, e1)
      ),
      Constants.CREATEX
    );
    address addr2 = SaltRef.create3(
      SaltRef.permissionedGuard(
        Constants.DEPLOYER, SaltRef.rawSalt(Constants.DEPLOYER, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, e2)
      ),
      Constants.CREATEX
    );

    assertTrue(addr1 != addr2, 'two different salt entropies reach the same address');
  }
}
