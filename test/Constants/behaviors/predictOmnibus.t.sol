// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Constants} from '../../../script/Constants.sol';
import {DeployConstants} from '../../../script/DeployConstants.sol';
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

  // ============ Registry lock (generated file ↔ source) ============

  /// @dev `sdk/src/deployments.json` is GENERATED from DeployConstants by
  ///      `make sync-registry`, and it is what `sdk/src/deployments.ts` ships to
  ///      every SDK consumer. Nothing stops someone hand-editing it or
  ///      forgetting to re-run sync after a label change, and either failure is
  ///      invisible: the file stays internally consistent while describing a
  ///      deployment the source no longer produces.
  ///
  ///      `make verify-omnibus` checks this too, but only when an operator
  ///      remembers to run it — this is the copy that runs in CI. Both call the
  ///      same assertion so they cannot disagree about what "correct" means.
  function test_predictOmnibus_registryMatchesDeployConstants() public view {
    Deployments.requireDerived(Deployments.readAll());
  }

  /// @dev Every row is recomputed from its OWN version label, so a family that
  ///      redeploys under a new label is covered the moment DeployConstants is
  ///      edited and sync is re-run, with no test change.
  function test_predictOmnibus_registryAddressesDeriveFromTheirVersion() public view {
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

  /// @dev A chain must belong to exactly one family. Overlap would make
  ///      `labelFor` order-dependent and give one chain two addresses.
  function test_predictOmnibus_chainFamiliesDoNotOverlap() public pure {
    uint256[] memory mainnets = DeployConstants.mainnetChains();
    uint256[] memory testnets = DeployConstants.testnetChains();

    for (uint256 i; i < mainnets.length; i++) {
      assertFalse(DeployConstants.isTestnet(mainnets[i]), 'a mainnet chain is also listed as a testnet');
    }
    for (uint256 i; i < testnets.length; i++) {
      assertFalse(DeployConstants.isMainnet(testnets[i]), 'a testnet chain is also listed as a mainnet');
    }
  }

  /// @dev The word stored in the Omnibus VERSION immutable must be the same
  ///      label the salt hashes — otherwise a deployment's on-chain identity
  ///      and its address would describe different versions.
  function test_predictOmnibus_versionWordMatchesLabel() public pure {
    assertEq(DeployConstants.versionWord(SALT_LABEL), bytes32(bytes(SALT_LABEL)), 'version word is not the label');
    assertEq(
      DeployConstants.versionWord(DeployConstants.MAINNET_LABEL),
      bytes32(bytes(DeployConstants.MAINNET_LABEL)),
      'mainnet version word is not its label'
    );
    assertEq(
      DeployConstants.versionWord(DeployConstants.TESTNET_LABEL),
      bytes32(bytes(DeployConstants.TESTNET_LABEL)),
      'testnet version word is not its label'
    );
  }

  /// @dev The masking in versionWord must drop everything past the label, or a
  ///      short label would carry adjacent memory into the immutable.
  function testFuzz_predictOmnibus_versionWordMasksTrailingBytes(bytes32 raw) public pure {
    string memory short_ = 'ab';
    bytes32 word = DeployConstants.versionWord(short_);

    assertEq(word, bytes32(bytes(short_)), 'version word carried trailing bytes');
    assertEq(uint256(word) & type(uint240).max, 0, 'bytes past the label length are not zero');
    raw; // silence unused-parameter warning; the fuzzer varies memory around the call
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
