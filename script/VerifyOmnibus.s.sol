// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {Constants} from './Constants.sol';
import {Deployments} from './Deployments.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';

/**
 * @title VerifyOmnibus
 * @dev Recomputes every row in the deployment registry and asserts the recorded
 *      address is the one its recorded `version` label derives to. Keeps
 *      `sdk/src/deployments.json` — what `sdk/src/deployments.ts` ships to every
 *      SDK consumer — honest about what the salt math actually produces.
 *
 *      Pure offline math — no RPC, no on-chain calls, no environment. An
 *      address is solely a function of (CreateX, Constants.DEPLOYER, salt), and
 *      the salt math lives in `Constants`, shared with DeployOmnibus, so the two
 *      cannot drift.
 *
 *      WHAT THIS DOES NOT CHECK: that the recorded contract is really there, or
 *      that its `walletFactory` matches the row. Both need an RPC. A row can be
 *      arithmetically perfect and still describe a deployment that was never
 *      broadcast — CREATE3 addresses are predictable, which is the point.
 *
 *      ANY divergence throws loudly — INCLUDING a zero address, so a
 *      declared-but-not-yet-deployed row fails rather than passing silently
 *      (usable as a hard pre-publish gate).
 *
 *      This same assertion also runs in CI as
 *      `Constants_predictOmnibus.test_predictOmnibus_matchesRegistry`. This
 *      script exists for the DEPLOYMENTS_JSON override — vetting a candidate
 *      file before publishing it — and for operator-facing output.
 *
 * Usage:
 *   forge script script/VerifyOmnibus.s.sol -v                   (no RPC needed)
 *   DEPLOYMENTS_JSON=path/to/other.json forge script script/VerifyOmnibus.s.sol -v
 *
 * Environment:
 *   DEPLOYMENTS_JSON - optional; overrides sdk/src/deployments.json (absolute or
 *                      repo-root-relative)
 */
contract VerifyOmnibus is Script {
  function run() external view {
    string memory path = vm.envOr('DEPLOYMENTS_JSON', Deployments.defaultPath());
    Deployments.Deployment[] memory rows = Deployments.readAll(path);

    console.log('Registry path:', path);
    console.log('Deployer EOA: ', Constants.DEPLOYER);
    console.log('Rows:         ', rows.length);
    require(rows.length > 0, 'VerifyOmnibus: registry is empty');

    for (uint256 i; i < rows.length; i++) {
      Deployments.Deployment memory row = rows[i];
      console.log('');
      console.log('  chain id:      ', row.chainId);
      console.log('  version:       ', row.version);
      console.log('  omnibus:       ', row.omnibus);
      console.log('  wallet factory:', row.walletFactory);
      console.log('  deployed:      ', row.deployed);
      console.log('  predicted:     ', Constants.predictOmnibus(row.version));

      // One row per chain. A duplicate would make resolution order-dependent —
      // and the SDK's Map build would silently keep only the last one.
      for (uint256 j = i + 1; j < rows.length; j++) {
        require(rows[j].chainId != row.chainId, 'VerifyOmnibus: duplicate row for the same chain id');
      }
    }

    // THE check: the committed file must be exactly what DeployConstants
    // derives. Every per-field assertion lives in one place so this script and
    // the CI test cannot disagree about what "correct" means.
    Deployments.requireDerived(rows);

    console.log('');
    console.log('OK - registry matches DeployConstants (addresses, versions, wallet factory)');
  }
}
