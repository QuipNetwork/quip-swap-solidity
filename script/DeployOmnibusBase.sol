// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {Omnibus} from '../src/Omnibus.sol';
import {IWalletFactory} from '../src/interfaces/IWalletFactory.sol';
import {Constants} from './Constants.sol';
import {DeployConstants} from './DeployConstants.sol';
import {ICreateX} from './ICreateX.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';
import {VmSafe} from 'forge-std-1.14.0/Vm.sol';

/**
 * @title DeployOmnibusBase
 * @dev Every gate for an Omnibus deployment, shared by DeployMainnet and
 *      DeployTestnet. The subclasses supply only a label and an allowlist —
 *      duplicating the gates across two scripts would be two copies free to
 *      drift, and a gate that exists in one script and not the other is worse
 *      than no split at all.
 *
 *      WHY THIS SCRIPT IS ALL ASSERTIONS. A wrong caller does NOT revert inside
 *      CreateX. It fails the sender-prefix match, silently takes a different
 *      guard branch, and deploys SUCCESSFULLY at an unrelated address. Every
 *      gate below exists because that failure mode is silent, and they all run
 *      BEFORE `vm.startBroadcast` so a bad configuration costs nothing.
 *
 *      NOTHING THAT DECIDES THE ADDRESS COMES FROM THE ENVIRONMENT. The
 *      deployer is `Constants.DEPLOYER`, the label and the wallet factory are
 *      in `DeployConstants`, and the chain must be in the subclass's allowlist.
 *      Env supplies only the signing key and the initial owner — neither of
 *      which can move the address or brick a route. That is deliberate: the
 *      wrong-factory incident happened through an env var that passed every
 *      liveness check it was given.
 *
 *      SAFE / MULTISIG ROUTING IS NOT SUPPORTED, by construction. CreateX keys
 *      its guard off `msg.sender`, so a Safe-executed deploy has
 *      `msg.sender == theSafe`, parses as a non-permissioned salt, and lands at
 *      a completely different address.
 *
 *      Local rehearsal: bare Anvil has no CreateX — rehearse against a fork of a
 *      chain that does (`make anvil-fork RPC=...`).
 *
 * Environment:
 *   DEPLOYER_PK       - Ops wallet private key. MUST derive Constants.DEPLOYER.
 *   OMNIBUS_OWNER     - Initial owner of the Omnibus (Ownable2Step)
 *   EXPECTED_CHAIN_ID - Optional. Belt-and-braces on top of the allowlist.
 */
abstract contract DeployOmnibusBase is Script {
  /// @dev The build profile whose compiler settings produce the artifact we
  ///      ship (metadata stripped, dedicated out dir). See [profile.prod].
  string internal constant REQUIRED_PROFILE = 'prod';

  /// @notice The salt version label this script deploys under.
  function label() internal pure virtual returns (string memory);

  /// @notice The chain ids this script is allowed to broadcast to.
  function allowedChains() internal pure virtual returns (uint256[] memory);

  /// @notice Human-readable family name, for logs and error messages.
  function family() internal pure virtual returns (string memory);

  function run() external {
    uint256 privateKey = vm.envUint('DEPLOYER_PK');
    address omnibusOwner = vm.envAddress('OMNIBUS_OWNER');

    address broadcaster = vm.addr(privateKey);
    string memory profile = vm.envOr('FOUNDRY_PROFILE', string('default'));

    string memory versionLabel = label();
    bytes32 versionWord = DeployConstants.versionWord(versionLabel);
    address walletFactory = DeployConstants.walletFactoryFor(block.chainid);
    bytes32 rawSalt = Constants.omnibusSalt(versionLabel);
    address expectedAddr = Constants.predictOmnibus(versionLabel);

    // ── 0. Log the whole picture BEFORE the first require, so a run that fails
    //       a gate is diagnosable from the same output a successful run gives.
    console.log('Family:            ', family());
    console.log('Profile:           ', profile);
    console.log('Chain id:          ', block.chainid);
    console.log('Version label:     ', versionLabel);
    console.log('Broadcaster (PK):  ', broadcaster);
    console.log('tx.origin:         ', tx.origin);
    console.log('Constants.DEPLOYER:', Constants.DEPLOYER);
    console.log('Expected Omnibus:  ', expectedAddr);
    console.log('Omnibus owner:     ', omnibusOwner);
    console.log('Wallet factory:    ', walletFactory);
    console.log('Raw salt:');
    console.logBytes32(rawSalt);
    console.log('Guarded salt:');
    console.logBytes32(Constants.guardedSalt(versionLabel));

    // ── 1. Build provenance. Catches a dev-profile artifact reaching a chain.
    require(
      keccak256(bytes(profile)) == keccak256(bytes(REQUIRED_PROFILE)),
      'DeployOmnibus: FOUNDRY_PROFILE must be prod (use the make deploy targets)'
    );

    // ── 2. Signer identity. THE gate. Any other key deploys a different,
    //       unadvertised Omnibus and still satisfies every post-condition.
    require(broadcaster == Constants.DEPLOYER, 'DeployOmnibus: DEPLOYER_PK does not derive Constants.DEPLOYER');

    // ── 3. Secondary signer gate for the --sender / --unlocked / hardware paths,
    //       where the broadcast identity is NOT derived from DEPLOYER_PK.
    //       Broadcast-only: a dry run without --private-key/--sender runs under
    //       forge's default sender and would trip this spuriously.
    if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
      require(tx.origin == Constants.DEPLOYER, 'DeployOmnibus: tx.origin is not Constants.DEPLOYER');
    }

    // ── 4. Chain allowlist. THE gate the script split exists for: choosing the
    //       right script does not stop an rpc-alias typo from pointing the
    //       MAINNET label at a testnet, which would burn a mainnet address on a
    //       throwaway chain and split the family.
    require(_chainAllowed(block.chainid), string.concat('DeployOmnibus: chain id not in the ', family(), ' allowlist'));

    uint256 expectedChainId = vm.envOr('EXPECTED_CHAIN_ID', uint256(0));
    if (expectedChainId != 0) {
      require(block.chainid == expectedChainId, 'DeployOmnibus: connected to the wrong chain');
    }

    // ── 5. Constructor args. WALLET_FACTORY is an immutable and the wallet route
    //       calls commitmentOf on it at runtime, so a wrong-but-nonempty address
    //       bricks that route permanently — probe the ABI, not just the code.
    //       The address itself is compiled in; this proves it is really present
    //       and really a factory ON THIS CHAIN.
    require(omnibusOwner != address(0), 'DeployOmnibus: OMNIBUS_OWNER must be non-zero');
    require(walletFactory.code.length > 0, 'DeployOmnibus: WALLET_FACTORY has no code on this chain');
    try IWalletFactory(walletFactory).commitmentOf(address(0)) returns (bytes32) {}
    catch {
      revert('DeployOmnibus: WALLET_FACTORY does not implement commitmentOf');
    }

    // ── 6. Factory presence + derivation agreement. The only gate that consults
    //       the real CreateX: it proves our local solady CREATE3 math and the
    //       on-chain factory derive the SAME address from the same guarded salt.
    require(Constants.CREATEX.code.length > 0, 'DeployOmnibus: CreateX not deployed on this chain');
    require(
      ICreateX(Constants.CREATEX).computeCreate3Address(Constants.guardedSalt(versionLabel)) == expectedAddr,
      'DeployOmnibus: CreateX disagrees with the local CREATE3 prediction'
    );

    // ── 7. Occupancy. A CREATE3 address ignores init code, so "has code" says
    //       nothing about WHAT is there. Never skip silently.
    if (expectedAddr.code.length > 0) {
      _requireOurOmnibusAt(expectedAddr, omnibusOwner, walletFactory, versionWord);
      console.log('\nOmnibus already deployed and verified at this address. Nothing to do.');
      return;
    }

    bytes memory bytecode =
      abi.encodePacked(type(Omnibus).creationCode, abi.encode(omnibusOwner, walletFactory, versionWord));

    vm.startBroadcast(privateKey);
    address deployed = ICreateX(Constants.CREATEX).deployCreate3(rawSalt, bytecode);
    vm.stopBroadcast();

    // Backstop for any branch divergence between our mirror and the factory.
    require(deployed == expectedAddr, 'DeployOmnibus: deployed address does not match the prediction');
    _requireOurOmnibusAt(deployed, omnibusOwner, walletFactory, versionWord);
    console.log('Omnibus deployed at:', deployed);
    console.log('Now run `make sync-registry RPC=...` to record it in sdk/src/deployments.json.');
  }

  /// @dev Asserts the contract at `addr` really is OUR Omnibus, using its
  ///      IMMUTABLES. `owner()` is deliberately not a hard check: Ownable2Step
  ///      ownership is transferable, so a legitimate re-run after a handover
  ///      must not revert. VERSION, WALLET_FACTORY and DOMAIN_SEPARATOR are
  ///      fixed at construction and cannot be changed by any post-deploy action.
  function _requireOurOmnibusAt(
    address addr,
    address expectedOwner,
    address expectedFactory,
    bytes32 expectedVersion
  ) internal view {
    Omnibus existing = Omnibus(payable(addr));

    // A non-Omnibus contract fails this staticcall; catch it so the operator
    // gets a legible message instead of a raw decoding failure.
    try existing.WALLET_FACTORY() returns (IWalletFactory factory) {
      require(address(factory) == expectedFactory, 'DeployOmnibus: address occupied - WALLET_FACTORY mismatch');
    } catch {
      revert('DeployOmnibus: address occupied by a contract that is not an Omnibus');
    }

    // The label the occupant says it was deployed under. Without this, an
    // occupied address can only be identified by inference.
    require(existing.VERSION() == expectedVersion, 'DeployOmnibus: address occupied - VERSION mismatch');

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

  function _chainAllowed(uint256 chainId) private pure returns (bool) {
    uint256[] memory chains = allowedChains();
    for (uint256 i; i < chains.length; i++) {
      if (chains[i] == chainId) return true;
    }
    return false;
  }
}
