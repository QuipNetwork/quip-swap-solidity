// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Constants} from '../../../script/Constants.sol';
import {Deployments} from '../../../script/Deployments.sol';
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
    assertEq(
      Constants.predictOmnibus(SALT_LABEL), LIVE_OMNIBUS, 'predicted address no longer matches the live deployment'
    );
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
      SaltRef.rawSalt(Constants.DEPLOYER, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, Constants.saltEntropy(SALT_LABEL));

    assertEq(
      Constants.predictOmnibus(SALT_LABEL),
      SaltRef.create3(SaltRef.permissionedGuard(Constants.DEPLOYER, salt), Constants.CREATEX),
      'solady-based prediction diverges from the longhand reference'
    );
  }

  // ============ Registry lock (docs ↔ code) ============

  /// @dev `sdk/src/deployments.json` is what `sdk/src/deployments.ts` ships to
  ///      every SDK consumer. `make verify-omnibus` checks this too, but only
  ///      when an operator remembers to run it — this is the copy that runs in
  ///      CI.
  ///
  ///      Every row is recomputed from its OWN version label, so a chain that
  ///      redeploys under a new label is covered the moment its row is edited,
  ///      with no test change. That is the whole point of recording the label
  ///      rather than only the address.
  function test_predictOmnibus_matchesRegistry() public view {
    Deployments.Deployment[] memory rows = Deployments.readAll();
    assertGt(rows.length, 0, 'deployment registry is empty');

    for (uint256 i; i < rows.length; i++) {
      assertEq(
        rows[i].omnibus,
        Constants.predictOmnibus(rows[i].version),
        'a registry row is out of sync with the address its version derives'
      );
    }
  }

  /// @dev One row per chain. A duplicate makes resolution order-dependent, and
  ///      the SDK's Map build would silently keep only the last one.
  function test_predictOmnibus_registryHasOneRowPerChain() public view {
    Deployments.Deployment[] memory rows = Deployments.readAll();

    for (uint256 i; i < rows.length; i++) {
      assertTrue(rows[i].chainId != 0, 'registry row has chain id 0');
      for (uint256 j = i + 1; j < rows.length; j++) {
        assertTrue(rows[i].chainId != rows[j].chainId, 'registry has duplicate rows for one chain id');
      }
    }
  }

  /// @dev The live Base Sepolia anchor must still be IN the registry — the
  ///      suite's known-answer tests are only meaningful while the registry
  ///      actually ships that address.
  function test_predictOmnibus_registryContainsLiveAnchor() public view {
    Deployments.Deployment[] memory rows = Deployments.readAll();

    assertTrue(Deployments.has(rows, 84_532), 'registry has no Base Sepolia row');
    assertEq(Deployments.forChain(rows, 84_532).omnibus, LIVE_OMNIBUS, 'Base Sepolia row is not the live Omnibus');
  }

  // ============ Anti-squat ============

  /// @dev Where our salt lands in a stranger's hands. Not merely "somewhere
  ///      else": CreateX's permissionless branch is deterministic, so the squat
  ///      target is exactly predictable — and must not be ours.
  function test_predictOmnibus_differsFromPermissionlessAddress() public pure {
    address squatted =
      SaltRef.create3(SaltRef.permissionlessGuard(Constants.omnibusSalt(SALT_LABEL)), Constants.CREATEX);

    assertTrue(
      squatted != Constants.predictOmnibus(SALT_LABEL), 'our salt in a foreign caller\'s hands reaches OUR address'
    );
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
        a, SaltRef.rawSalt(a, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, Constants.saltEntropy(SALT_LABEL))
      ),
      Constants.CREATEX
    );
    address addrB = SaltRef.create3(
      SaltRef.permissionedGuard(
        b, SaltRef.rawSalt(b, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, Constants.saltEntropy(SALT_LABEL))
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
