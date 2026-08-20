// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {Constants} from './Constants.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';

/**
 * @title VerifyOmnibus
 * @dev Predicts the Omnibus CREATE3 address from (CreateX, deployer EOA,
 *      salt) and asserts it equals `omnibusAddress` in the SDK address-json.
 *      Keeps the SDK's pinned address (`sdk/src/address.json`, surfaced as
 *      `OMNIBUS_CREATE3_ADDRESS`) in sync with what DeployOmnibus would deploy.
 *
 *      Pure offline math — no RPC, no on-chain calls. The address is solely a
 *      function of (CreateX, deployer EOA, salt) via the CreateX-guarded salt
 *      and the standard CREATE3 proxy, all known locally. The salt math lives
 *      in `Constants` and is shared with DeployOmnibus, so they cannot drift.
 *
 *      ANY divergence throws loudly — INCLUDING the zero placeholder, so a
 *      not-yet-populated address.json fails rather than passing silently
 *      (usable as a hard pre-publish gate).
 *
 * Usage:
 *   forge script script/legacy/VerifyOmnibus.s.sol --rpc-url $RPC -v   (RPC unused; any works)
 *   ADDRESS_JSON=path/to/other.json forge script script/legacy/VerifyOmnibus.s.sol -v
 *
 * Environment:
 *   DEPLOYER_ADDRESS - Deployer EOA the salt is permissioned to (the address
 *                      of DEPLOYER_PK used by DeployOmnibus)
 *   ADDRESS_JSON     - optional; overrides sdk/src/address.json (absolute or repo-root-relative)
 */
contract VerifyOmnibus is Script {
  function run() external view {
    address deployerEoa = vm.envAddress('DEPLOYER_ADDRESS');

    string memory defaultPath = string.concat(vm.projectRoot(), '/sdk/src/address.json');
    string memory path = vm.envOr('ADDRESS_JSON', defaultPath);
    address fromJson = vm.parseJsonAddress(vm.readFile(path), '.omnibusAddress');

    address predicted = Constants.predictOmnibus(deployerEoa);

    console.log('address.json path:', path);
    console.log('Deployer EOA:     ', deployerEoa);
    console.log('Predicted Omnibus:', predicted);
    console.log('address.json:     ', fromJson);

    require(fromJson == predicted, 'VerifyOmnibus: address.json does not match predicted Omnibus address');
    console.log('OK - address.json matches predicted Omnibus address');
  }
}
