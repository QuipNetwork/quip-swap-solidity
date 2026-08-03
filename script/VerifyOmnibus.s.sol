// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {Constants} from './Constants.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';

/**
 * @title VerifyOmnibus
 * @dev Predicts the Omnibus CREATE3 address and asserts it equals
 *      `omnibusAddress` in the SDK address-json. Keeps the SDK's pinned address
 *      (`sdk/src/address.json`, surfaced as `OMNIBUS_CREATE3_ADDRESS`) in sync
 *      with what DeployOmnibus would deploy.
 *
 *      Pure offline math — no RPC, no on-chain calls, no environment. The
 *      address is solely a function of (CreateX, Constants.DEPLOYER, salt), all
 *      compiled in. The salt math lives in `Constants` and is shared with
 *      DeployOmnibus, so the two cannot drift.
 *
 *      ANY divergence throws loudly — INCLUDING the zero placeholder, so a
 *      not-yet-populated address.json fails rather than passing silently
 *      (usable as a hard pre-publish gate).
 *
 *      This same assertion also runs in CI as
 *      `Constants_predictOmnibus.test_predictOmnibus_matchesSdkAddressJson`.
 *      This script exists for the ADDRESS_JSON override — vetting a candidate
 *      file before publishing it — and for operator-facing output.
 *
 * Usage:
 *   forge script script/VerifyOmnibus.s.sol -v                   (no RPC needed)
 *   ADDRESS_JSON=path/to/other.json forge script script/VerifyOmnibus.s.sol -v
 *
 * Environment:
 *   ADDRESS_JSON - optional; overrides sdk/src/address.json (absolute or repo-root-relative)
 */
contract VerifyOmnibus is Script {
  function run() external view {
    string memory defaultPath = string.concat(vm.projectRoot(), '/sdk/src/address.json');
    string memory path = vm.envOr('ADDRESS_JSON', defaultPath);
    address fromJson = vm.parseJsonAddress(vm.readFile(path), '.omnibusAddress');

    address predicted = Constants.predictOmnibus();

    console.log('address.json path:', path);
    console.log('Deployer EOA:     ', Constants.DEPLOYER);
    console.log('Predicted Omnibus:', predicted);
    console.log('address.json:     ', fromJson);

    require(fromJson == predicted, 'VerifyOmnibus: address.json does not match predicted Omnibus address');
    console.log('OK - address.json matches predicted Omnibus address');
  }
}
