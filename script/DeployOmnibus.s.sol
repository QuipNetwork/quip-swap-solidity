// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {Omnibus} from '../src/Omnibus.sol';
import {IWalletFactory} from '../src/interfaces/IWalletFactory.sol';
import {Constants} from './Constants.sol';
import {ICreateX} from './ICreateX.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';
import {VmSafe} from 'forge-std-1.14.0/Vm.sol';

/**
 * @title DeployOmnibus
 * @dev Deploys the Omnibus singleton via the canonical CreateX factory using
 *      CREATE3. The address depends only on (CreateX, Constants.DEPLOYER, salt)
 *      — the same on every chain, independent of constructor args. Owner and
 *      wallet factory differ per chain; the address does not.
 *
 *      WHY THIS SCRIPT IS ALL ASSERTIONS. A wrong caller does NOT revert inside
 *      CreateX. It fails the sender-prefix match, silently takes a different
 *      guard branch, and deploys SUCCESSFULLY at an unrelated address. Every
 *      gate below exists because that failure mode is silent, and they all run
 *      BEFORE `vm.startBroadcast` so a bad configuration costs nothing.
 *
 *      The deployer is compiled into `Constants.DEPLOYER` rather than read from
 *      the environment on purpose: a prediction derived from the live signer
 *      would follow a wrong key to its wrong address, and the post-deploy
 *      `deployed == expected` check would then PASS.
 *
 *      SAFE / MULTISIG ROUTING IS NOT SUPPORTED, by construction. CreateX keys
 *      its guard off `msg.sender`, so a Safe-executed deploy has
 *      `msg.sender == theSafe`, parses as a non-permissioned salt, and lands at
 *      a completely different address. This design binds the address to an EOA
 *      key; routing through a contract would require the salt to embed that
 *      contract's address instead.
 *
 *      Local rehearsal: bare Anvil has no CreateX — rehearse against a fork of a
 *      chain that does (`make anvil-fork RPC=...`).
 *
 * Usage:
 *   make deploy-dry RPC=API_URL_BASE_SEPOLIA    # rehearsal, no broadcast
 *   make deploy     RPC=API_URL_BASE_SEPOLIA    # broadcast + verify
 *
 * Environment:
 *   DEPLOYER_PK       - Ops wallet private key. MUST derive Constants.DEPLOYER.
 *   OMNIBUS_OWNER     - Initial owner of the Omnibus (Ownable2Step)
 *   WALLET_FACTORY    - The quip WalletFactory proxy on this chain (baked as an
 *                       immutable; gates the wallet commit route)
 *   EXPECTED_CHAIN_ID - Optional. When set, asserts the RPC really points at
 *                       that chain — catches an rpc-alias typo, which is a
 *                       likelier operator error than a wrong key.
 */
contract DeployOmnibus is Script {
  /// @dev The build profile whose compiler settings produce the artifact we
  ///      ship (metadata stripped, dedicated out dir). See [profile.prod].
  string internal constant REQUIRED_PROFILE = 'prod';

  function run() external {
    uint256 privateKey = vm.envUint('DEPLOYER_PK');
    address omnibusOwner = vm.envAddress('OMNIBUS_OWNER');
    address walletFactory = vm.envAddress('WALLET_FACTORY');

    address broadcaster = vm.addr(privateKey);
    string memory profile = vm.envOr('FOUNDRY_PROFILE', string('default'));
    bytes32 rawSalt = Constants.omnibusSalt();
    address expectedAddr = Constants.predictOmnibus();

    // ── 0. Log the whole picture BEFORE the first require, so a run that fails
    //       a gate is diagnosable from the same output a successful run gives.
    console.log('Profile:           ', profile);
    console.log('Chain id:          ', block.chainid);
    console.log('Broadcaster (PK):  ', broadcaster);
    console.log('tx.origin:         ', tx.origin);
    console.log('Constants.DEPLOYER:', Constants.DEPLOYER);
    console.log('Expected Omnibus:  ', expectedAddr);
    console.log('Omnibus owner:     ', omnibusOwner);
    console.log('Wallet factory:    ', walletFactory);
    console.log('Raw salt:');
    console.logBytes32(rawSalt);
    console.log('Guarded salt:');
    console.logBytes32(Constants.guardedSalt());

    // ── 1. Build provenance. Catches a dev-profile artifact reaching a chain.
    require(
      keccak256(bytes(profile)) == keccak256(bytes(REQUIRED_PROFILE)),
      'DeployOmnibus: FOUNDRY_PROFILE must be prod (use `make deploy` / `make deploy-dry`)'
    );

    // ── 2. Signer identity. THE gate. Any other key deploys a different,
    //       unadvertised Omnibus and still satisfies every post-condition.
    require(broadcaster == Constants.DEPLOYER, 'DeployOmnibus: DEPLOYER_PK does not derive Constants.DEPLOYER');

    // ── 3. Secondary signer gate for the --sender / --unlocked / hardware paths,
    //       where the broadcast identity is NOT derived from DEPLOYER_PK.
    //       Broadcast-only: a dry run without --private-key/--sender runs under
    //       forge's default sender and would trip this spuriously.
    //       NOTE this checks tx.origin, so it passes for a Safe-routed deploy
    //       even though CreateX would see the Safe as msg.sender. That case
    //       still fails closed at gate 6 / the post-deploy check, just with a
    //       vaguer message. See the Safe note in the contract docs.
    if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
      require(tx.origin == Constants.DEPLOYER, 'DeployOmnibus: tx.origin is not Constants.DEPLOYER');
    }

    // ── 4. Target chain, when the caller pinned one.
    uint256 expectedChainId = vm.envOr('EXPECTED_CHAIN_ID', uint256(0));
    if (expectedChainId != 0) {
      require(block.chainid == expectedChainId, 'DeployOmnibus: connected to the wrong chain');
    }

    // ── 5. Constructor args. WALLET_FACTORY is an immutable and the wallet route
    //       calls vaultIdOf on it at runtime, so a wrong-but-nonempty address
    //       bricks that route permanently — probe the ABI, not just the code.
    require(omnibusOwner != address(0), 'DeployOmnibus: OMNIBUS_OWNER must be non-zero');
    require(walletFactory != address(0), 'DeployOmnibus: WALLET_FACTORY must be non-zero');
    require(walletFactory.code.length > 0, 'DeployOmnibus: WALLET_FACTORY has no code on this chain');
    try IWalletFactory(walletFactory).vaultIdOf(address(0)) returns (bytes32) {}
    catch {
      revert('DeployOmnibus: WALLET_FACTORY does not implement vaultIdOf');
    }

    // ── 6. Factory presence + derivation agreement. The only gate that consults
    //       the real CreateX: it proves our local solady CREATE3 math and the
    //       on-chain factory derive the SAME address from the same guarded salt.
    require(Constants.CREATEX.code.length > 0, 'DeployOmnibus: CreateX not deployed on this chain');
    require(
      ICreateX(Constants.CREATEX).computeCreate3Address(Constants.guardedSalt()) == expectedAddr,
      'DeployOmnibus: CreateX disagrees with the local CREATE3 prediction'
    );

    // ── 7. Occupancy. A CREATE3 address ignores init code, so "has code" says
    //       nothing about WHAT is there. Never skip silently.
    if (expectedAddr.code.length > 0) {
      _requireOurOmnibusAt(expectedAddr, omnibusOwner, walletFactory);
      console.log('\nOmnibus already deployed and verified at this address. Nothing to do.');
      return;
    }

    bytes memory bytecode = abi.encodePacked(type(Omnibus).creationCode, abi.encode(omnibusOwner, walletFactory));

    vm.startBroadcast(privateKey);
    address deployed = ICreateX(Constants.CREATEX).deployCreate3(rawSalt, bytecode);
    vm.stopBroadcast();

    // Backstop for any branch divergence between our mirror and the factory.
    require(deployed == expectedAddr, 'DeployOmnibus: deployed address does not match the prediction');
    _requireOurOmnibusAt(deployed, omnibusOwner, walletFactory);
    console.log('Omnibus deployed at:', deployed);
  }

  /// @dev Asserts the contract at `addr` really is OUR Omnibus, using its
  ///      IMMUTABLES. `owner()` is deliberately not a hard check: Ownable2Step
  ///      ownership is transferable, so a legitimate re-run after a handover
  ///      must not revert. WALLET_FACTORY and DOMAIN_SEPARATOR are fixed at
  ///      construction and cannot be changed by any post-deploy action.
  function _requireOurOmnibusAt(address addr, address expectedOwner, address expectedFactory) internal view {
    Omnibus existing = Omnibus(payable(addr));

    // A non-Omnibus contract fails this staticcall; catch it so the operator
    // gets a legible message instead of a raw decoding failure.
    try existing.WALLET_FACTORY() returns (IWalletFactory factory) {
      require(address(factory) == expectedFactory, 'DeployOmnibus: address occupied - WALLET_FACTORY mismatch');
    } catch {
      revert('DeployOmnibus: address occupied by a contract that is not an Omnibus');
    }

    // Binds COMMIT_DIGEST_TAG + chainid + address, all recomputable locally.
    require(
      existing.DOMAIN_SEPARATOR() == keccak256(abi.encode(existing.COMMIT_DIGEST_TAG(), block.chainid, addr)),
      'DeployOmnibus: address occupied - DOMAIN_SEPARATOR mismatch'
    );

    address currentOwner = existing.owner();
    if (currentOwner != expectedOwner) {
      console.log('WARNING: on-chain owner differs from OMNIBUS_OWNER (transferred?):', currentOwner);
    }
  }
}
