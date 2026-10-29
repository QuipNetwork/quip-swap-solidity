// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {DeployConstants} from './DeployConstants.sol';
import {DeployOmnibusBase} from './DeployOmnibusBase.sol';

/**
 * @title DeployMainnet
 * @dev Deploys the Omnibus to a MAINNET chain under `MAINNET_LABEL`.
 *
 *      Deliberately separate from DeployTestnet so a mainnet deploy cannot pick
 *      up a testnet label by passing the wrong argument — there is no argument.
 *      The allowlist in the base then catches the remaining error, an rpc alias
 *      pointing somewhere else entirely.
 *
 * Usage:
 *   make deploy-base-dry     # rehearsal, no broadcast
 *   make deploy-base         # broadcast + verify
 */
contract DeployMainnet is DeployOmnibusBase {
  function label() internal pure override returns (string memory) {
    return DeployConstants.MAINNET_LABEL;
  }

  function allowedChains() internal pure override returns (uint256[] memory) {
    return DeployConstants.mainnetChains();
  }

  function family() internal pure override returns (string memory) {
    return 'mainnet';
  }
}
