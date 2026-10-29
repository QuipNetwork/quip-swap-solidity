// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {Constants} from './Constants.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';
import {CREATE3} from 'solady-0.1.26/utils/CREATE3.sol';

/**
 * @title VerifyOmnibus
 * @dev Predicts the Omnibus CREATE3 address from (Deployer, SALT) and asserts
 *      it equals `omnibusAddress` in the SDK address-json. Keeps the SDK's
 *      pinned address (`sdk/src/address.json`, surfaced as
 *      `OMNIBUS_CREATE3_ADDRESS`) in sync with what DeployOmnibus would deploy.
 *
 *      Pure offline math — no RPC, no on-chain calls. The address is solely a
 *      function of (Deployer, salt) via solady CREATE3, both known locally.
 *      SALT MUST match DeployOmnibus.SALT.
 *
 *      ANY divergence throws loudly — INCLUDING the zero placeholder, so a
 *      not-yet-populated address.json fails rather than passing silently
 *      (usable as a hard pre-publish gate).
 *
 * Usage:
 *   forge script script/VerifyOmnibus.s.sol --rpc-url $RPC -v   (RPC unused; any works)
 *   ADDRESS_JSON=path/to/other.json forge script script/VerifyOmnibus.s.sol -v
 *
 * Environment:
 *   DEPLOYER_ADDRESS - Deployer contract address (same as DeployOmnibus)
 *   ADDRESS_JSON     - optional; overrides sdk/src/address.json (absolute or repo-root-relative)
 */
contract VerifyOmnibus is Script {
  bytes32 internal constant SALT = Constants.OMNIBUS_SALT;

  function run() external view {
    address deployerAddr = vm.envAddress('DEPLOYER_ADDRESS');

    string memory defaultPath = string.concat(vm.projectRoot(), '/sdk/src/address.json');
    string memory path = vm.envOr('ADDRESS_JSON', defaultPath);
    address fromJson = vm.parseJsonAddress(vm.readFile(path), '.omnibusAddress');

    address predicted = CREATE3.predictDeterministicAddress(SALT, deployerAddr);

    console.log('address.json path:', path);
    console.log('Deployer:         ', deployerAddr);
    console.log('Predicted Omnibus:', predicted);
    console.log('address.json:     ', fromJson);

    require(fromJson == predicted, 'VerifyOmnibus: address.json does not match predicted Omnibus address');
    console.log('OK - address.json matches predicted Omnibus address');
  }
}
