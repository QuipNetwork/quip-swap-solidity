// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {Omnibus} from '../src/Omnibus.sol';
import {IWalletFactory} from '../src/interfaces/IWalletFactory.sol';
import {Constants} from './Constants.sol';
import {DeployConstants} from './DeployConstants.sol';
import {Deployments} from './Deployments.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';

/**
 * @title SyncRegistry
 * @dev Regenerates `sdk/src/deployments.json` from `DeployConstants`. The
 *      registry is DERIVED — chain ids, labels and the wallet factory come from
 *      the deploy scripts, and the address is `predictOmnibus(label)`. Editing
 *      the JSON by hand is not how you change a deployment; a CI test
 *      re-derives it and fails if the committed file diverges.
 *
 *      THE ONE FIELD THAT CANNOT BE DERIVED is `deployed`. A CREATE3 address is
 *      predictable whether or not anything was ever deployed to it, so without
 *      this flag the registry would advertise addresses with no code and
 *      `resolveDeployment` would stop meaning "there is an Omnibus here".
 *      Liveness needs an RPC, so:
 *
 *        - run WITHOUT --rpc-url: every row's existing `deployed` flag is
 *          carried over unchanged (safe for a pure label/chain edit)
 *        - run WITH --rpc-url: the CONNECTED chain's row is additionally
 *          re-checked against real code, and its flag updated
 *
 *      So a full refresh is one run per chain. That is deliberate over a
 *      multi-RPC loop: each run proves liveness with the same RPC the deploy
 *      used, and a chain you cannot reach keeps its last known state instead of
 *      being silently downgraded to false.
 *
 * Usage:
 *   make sync-registry                      # derive, preserve liveness flags
 *   make sync-registry RPC=API_URL_BASE_SEPOLIA   # + refresh this chain's flag
 */
contract SyncRegistry is Script {
  function run() external {
    string memory path = Deployments.defaultPath();
    bool[] memory priorDeployed = _priorFlags(path);

    uint256[] memory mainnets = DeployConstants.mainnetChains();
    uint256[] memory testnets = DeployConstants.testnetChains();
    uint256 total = mainnets.length + testnets.length;

    string memory rows = '';
    uint256 index;
    for (uint256 i; i < total; i++) {
      uint256 chainId = i < mainnets.length ? mainnets[i] : testnets[i - mainnets.length];
      string memory versionLabel = DeployConstants.labelFor(chainId);
      address omnibus = Constants.predictOmnibus(versionLabel);
      bool deployed = _liveness(chainId, omnibus, priorDeployed, index);

      rows = string.concat(
        rows,
        index == 0 ? '' : ',\n',
        '    {\n',
        '      "chainId": ',
        vm.toString(chainId),
        ',\n',
        '      "deployed": ',
        deployed ? 'true' : 'false',
        ',\n',
        '      "omnibus": "',
        vm.toString(omnibus),
        '",\n',
        '      "version": "',
        versionLabel,
        '",\n',
        '      "walletFactory": "',
        vm.toString(DeployConstants.WALLET_FACTORY),
        '"\n',
        '    }'
      );
      console.log(deployed ? '  [deployed]    ' : '  [not deployed]', chainId, versionLabel, omnibus);
      index++;
    }

    vm.writeFile(path, string.concat(_header(), '  "deployments": [\n', rows, '\n  ]\n}\n'));
    console.log('\nWrote', path);
  }

  /// @dev Existing flags, indexed the same way the rows are rebuilt. A chain
  ///      that was not in the old file defaults to false — never to true.
  ///
  ///      The `deployed` probe guards the bootstrap case: a registry written
  ///      before the field existed cannot decode into the current struct, and
  ///      must degrade to "nothing known to be deployed" rather than reverting.
  ///      (A script cannot wrap the decode in try/catch — forge rejects
  ///      `address(this)` in scripts — so the shape is checked up front.)
  function _priorFlags(string memory path) private view returns (bool[] memory flags) {
    uint256[] memory mainnets = DeployConstants.mainnetChains();
    uint256[] memory testnets = DeployConstants.testnetChains();
    flags = new bool[](mainnets.length + testnets.length);

    if (!vm.exists(path)) return flags;
    if (!vm.keyExistsJson(vm.readFile(path), '.deployments[0].deployed')) return flags;

    Deployments.Deployment[] memory prior = Deployments.readAll(path);

    for (uint256 i; i < flags.length; i++) {
      uint256 chainId = i < mainnets.length ? mainnets[i] : testnets[i - mainnets.length];
      address current = Constants.predictOmnibus(DeployConstants.labelFor(chainId));
      for (uint256 j; j < prior.length; j++) {
        // Only carry the flag when the row still describes the SAME address. A
        // label bump moves the address, and the old chain's `true` must not
        // follow it to a contract that was never deployed.
        if (prior[j].chainId == chainId && prior[j].omnibus == current) {
          flags[i] = prior[j].deployed;
        }
      }
    }
  }

  /// @dev Whether the Omnibus THIS BUILD DESCRIBES is live on `chainId`.
  ///
  ///      Deliberately stricter than "has code". A CREATE3 address ignores init
  ///      code, so code at the right address proves nothing about what is
  ///      there — that is precisely how Base Sepolia and OP Sepolia ended up
  ///      holding an Omnibus wired to a non-canonical WalletFactory while
  ///      looking perfectly healthy. A row that claims `deployed: true` while
  ///      the live contract disagrees with `DeployConstants` would launder that
  ///      same mistake into the SDK, so the factory immutable must match.
  ///
  ///      VERSION is reported but not yet gated on: deployments predating the
  ///      immutable have no label to compare, and failing them would mark a
  ///      correct mainnet deployment as dead. Once every chain is redeployed on
  ///      the current contract, promote the warning to a condition.
  function _liveness(uint256 chainId, address omnibus, bool[] memory prior, uint256 index) private view returns (bool) {
    // Only the connected chain can be checked for real; others keep their last
    // known state rather than being silently downgraded.
    if (chainId != block.chainid) return prior[index];
    if (omnibus.code.length == 0) return false;

    Omnibus live = Omnibus(payable(omnibus));

    address liveFactory;
    try live.WALLET_FACTORY() returns (IWalletFactory factory) {
      liveFactory = address(factory);
    } catch {
      console.log('  WARNING: contract at the predicted address is not an Omnibus; recording not-deployed.');
      return false;
    }

    if (liveFactory != DeployConstants.WALLET_FACTORY) {
      console.log('  WARNING: live WALLET_FACTORY does not match DeployConstants:', liveFactory);
      console.log('           recording not-deployed - this chain needs a redeploy.');
      return false;
    }

    try live.VERSION() returns (bytes32 liveVersion) {
      bytes32 expected = DeployConstants.versionWord(DeployConstants.labelFor(chainId));
      if (liveVersion != expected) {
        console.log('  NOTE: live VERSION does not match this build (pre-VERSION deployment?).');
      }
    } catch {
      console.log('  NOTE: live contract has no bytes32 VERSION (deployed before it existed).');
    }

    return true;
  }

  function _header() private pure returns (string memory) {
    return string.concat(
      '{\n',
      '  "_comment": "GENERATED by `make sync-registry` from script/DeployConstants.sol. ',
      'Do not hand-edit: a CI test re-derives every row and fails if this file diverges. ',
      'To change a deployment, edit DeployConstants (label, wallet factory, chain lists) and re-run sync. ',
      "The 'omnibus' field is predictOmnibus(version), pure offline math. The 'deployed' field is the one ",
      'field that cannot be derived (a CREATE3 address is predictable whether or not anything was deployed ',
      'to it) and is refreshed per-chain by running sync with that chain rpc-url.",\n'
    );
  }
}
