// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Constants} from '../../../script/Constants.sol';
import {ICreateX} from '../../../script/ICreateX.sol';
import {Omnibus} from '../../../src/Omnibus.sol';
import {SaltRef} from '../../utils/SaltRef.sol';

/// @title CreateX Permissioned-Guard Fork Tests
/// @dev The ONLY test that validates the guard formula against the real
///      CreateX bytecode. Everything else in test/Constants/ checks our local
///      mirror against literals and against a reference implementation — but
///      both of those are documentation of what CreateX does, and documentation
///      can be wrong. This executes the factory itself.
///
///      Run before any broadcast: `make test-fork RPC=API_URL_BASE_SEPOLIA`.
///
///      GATING. CI has no RPC secrets, so `setUp` self-skips when
///      API_URL_BASE_SEPOLIA is unset. That is deliberately preferred over
///      excluding the file from the default test path: a test that CI never
///      compiles is a test that silently rots. Here CI still typechecks it, and
///      the assertions run wherever an RPC is configured.
///
///      The env var is read directly rather than through `vm.rpcUrl` /
///      `[rpc_endpoints]`, because the alias interpolates `${API_URL_BASE_SEPOLIA}`
///      and hard-errors when unset — which cannot be skipped.
contract Constants_CreateXFork is Test {
  /// @dev Pinned so runs are deterministic and cached after the first fetch.
  ///      Must be at or after 44491571, the block the live Omnibus was deployed
  ///      in, so the "matches the live deployment" test below has something to
  ///      look at.
  uint256 internal constant FORK_BLOCK = 44_500_000;

  /// @dev Base Sepolia, where the live Omnibus this suite anchors to lives.
  uint256 internal constant FORK_CHAIN_ID = 84_532;

  /// @dev The salt label the live Base Sepolia Omnibus was deployed under.
  ///      Pinned here rather than read from the registry: this suite anchors to
  ///      what is ON the fork at FORK_BLOCK, which no later registry edit can
  ///      change. When Base Sepolia is redeployed under a new label, this
  ///      constant and FORK_BLOCK move together or not at all.
  string internal constant SALT_LABEL = 'QUIP:Omnibus:v1.0.0-alpha.2';

  /// @dev The WalletFactory baked into the live Omnibus's immutables. NOT the
  ///      canonical proxy (0xdCD90563…): this deployment was wired to a
  ///      testnet-only duplicate, which is why the wallet commit route reverts
  ///      NotQuipWallet on Base Sepolia and why a redeploy is pending.
  address internal constant LIVE_WALLET_FACTORY = 0x6de121F7cc8b310aDBc957425B97e1C8dfcE3BE5;

  /// @dev Fresh entropy for the deploy tests. The REAL salt's address is already
  ///      occupied at this block, and CreateX reverts on a collision — so
  ///      exercising an actual deployment needs an unclaimed salt.
  bytes11 internal constant TEST_ENTROPY = bytes11(keccak256('QUIP:Omnibus:fork-test-only'));

  address internal constant STRANGER = address(0xBAD);

  ICreateX internal createX = ICreateX(Constants.CREATEX);

  function setUp() public {
    string memory rpc = vm.envOr('API_URL_BASE_SEPOLIA', string(''));
    if (bytes(rpc).length == 0) {
      // No RPC configured (CI). Skip the whole contract rather than fail.
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc, FORK_BLOCK);
  }

  // ============ Setup assertions ============

  /// @dev Everything below tests "what the real CreateX does", so first
  ///      establish that the fork actually carries the canonical factory.
  function test_setUp() public view {
    assertEq(block.chainid, FORK_CHAIN_ID, 'fork is not Base Sepolia');
    assertGt(Constants.CREATEX.code.length, 0, 'CreateX has no code on this fork');
  }

  // ============ The guard formula, against real bytecode ============

  /// @dev The cross-check the deploy script performs at gate 6: our offline
  ///      solady-based prediction must equal what the factory itself computes
  ///      for the same guarded salt.
  function test_computeCreate3Address_agreesWithLocalPrediction() public view {
    assertEq(
      createX.computeCreate3Address(Constants.guardedSalt(SALT_LABEL)),
      Constants.predictOmnibus(SALT_LABEL),
      'CreateX disagrees with the local CREATE3 prediction'
    );
  }

  /// @dev The positive case: DEPLOYER passing a salt permissioned to itself
  ///      lands exactly where the reference derivation says it will. This is
  ///      what proves the MsgSender + no-redeploy-protection branch is the one
  ///      our salt layout actually selects.
  function test_deployCreate3_asDeployer_landsAtPredictedAddress() public {
    bytes32 salt = SaltRef.rawSalt(Constants.DEPLOYER, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, TEST_ENTROPY);
    address expected = SaltRef.create3(SaltRef.permissionedGuard(Constants.DEPLOYER, salt), Constants.CREATEX);

    vm.prank(Constants.DEPLOYER);
    address deployed = createX.deployCreate3(salt, _omnibusInitCode());

    assertEq(deployed, expected, 'permissioned deploy did not land at the predicted address');
    assertGt(deployed.code.length, 0, 'nothing deployed');
  }

  /// @dev THE anti-squat proof, using our REAL production salt.
  ///
  ///      Note what is asserted: the call does NOT revert. A stranger can
  ///      absolutely call CreateX with our salt and succeed — CreateX simply
  ///      fails the sender-prefix match, falls to the permissionless branch,
  ///      and deploys somewhere else entirely. That silent fallback is the
  ///      whole hazard this design is built around, and it is why the address
  ///      is safe: the stranger's code lands at a deterministic OTHER address,
  ///      and ours is untouched.
  function test_deployCreate3_asStranger_withOurSalt_landsElsewhere() public {
    bytes32 ourSalt = Constants.omnibusSalt(SALT_LABEL);
    address ours = Constants.predictOmnibus(SALT_LABEL);
    bytes32 oursCodehashBefore = ours.codehash;

    vm.prank(STRANGER);
    address squatted = createX.deployCreate3(ourSalt, _omnibusInitCode());

    assertTrue(squatted != ours, 'a stranger using our salt reached OUR address');
    assertEq(
      squatted,
      SaltRef.create3(SaltRef.permissionlessGuard(ourSalt), Constants.CREATEX),
      'stranger did not land on the permissionless branch'
    );
    assertEq(ours.codehash, oursCodehashBefore, 'our address was disturbed');
  }

  /// @dev The motivating operator error: a wrong signer with a salt permissioned
  ///      to ITSELF. CreateX does not revert; it deploys successfully at a
  ///      different, unadvertised address. Were the deploy script's prediction
  ///      derived from the live signer instead of the compiled-in
  ///      Constants.DEPLOYER, this run would pass every post-deploy check.
  function test_deployCreate3_asStranger_withOwnSalt_landsElsewhere() public {
    bytes32 strangerSalt = SaltRef.rawSalt(STRANGER, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, TEST_ENTROPY);

    vm.prank(STRANGER);
    address deployed = createX.deployCreate3(strangerSalt, _omnibusInitCode());

    assertGt(deployed.code.length, 0, 'stranger deploy unexpectedly produced no code');
    assertTrue(deployed != Constants.predictOmnibus(SALT_LABEL), 'a wrong signer reached OUR address');
    assertEq(
      deployed,
      SaltRef.create3(SaltRef.permissionedGuard(STRANGER, strangerSalt), Constants.CREATEX),
      'wrong signer did not land on its own permissioned address'
    );
  }

  // ============ End-to-end: library math against the live chain ============

  /// @dev Closes the loop. Every other test compares derivations to each other;
  ///      this one confirms the address our library predicts is occupied, on a
  ///      real chain, by the Omnibus we think is there.
  function test_predictOmnibus_matchesDeployedOmnibusOnBaseSepolia() public view {
    address predicted = Constants.predictOmnibus(SALT_LABEL);
    assertGt(predicted.code.length, 0, 'no Omnibus deployed at the predicted address');

    Omnibus live = Omnibus(payable(predicted));
    assertEq(address(live.WALLET_FACTORY()), LIVE_WALLET_FACTORY, 'WALLET_FACTORY immutable mismatch');
    assertEq(
      live.DOMAIN_SEPARATOR(),
      keccak256(abi.encode(live.COMMIT_DIGEST_TAG(), FORK_CHAIN_ID, predicted)),
      'DOMAIN_SEPARATOR does not recompute'
    );
  }

  // ============ Helpers ============

  /// @dev Constructor args are irrelevant to a CREATE3 address, so any valid
  ///      pair works. The factory must be non-zero (the Omnibus constructor
  ///      reverts on ZeroFactory).
  function _omnibusInitCode() internal pure returns (bytes memory) {
    return abi.encodePacked(type(Omnibus).creationCode, abi.encode(Constants.DEPLOYER, LIVE_WALLET_FACTORY));
  }
}
