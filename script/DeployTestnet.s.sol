// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {DeployConstants} from './DeployConstants.sol';
import {DeployOmnibusBase} from './DeployOmnibusBase.sol';

/**
 * @title DeployTestnet
 * @dev Deploys the Omnibus to a TESTNET chain under `TESTNET_LABEL`.
 *
 *      Bumping TESTNET_LABEL moves the address on every testnet at once, so a
 *      bump means redeploying every chain in `DeployConstants.testnetChains()`
 *      as a batch. Deploying only some of them leaves the family split across
 *      two addresses; the registry consistency test is what makes that visible
 *      rather than silent.
 *
 * Usage:
 *   make deploy-base-sepolia-dry   # rehearsal, no broadcast
 *   make deploy-base-sepolia       # broadcast + verify
 *   make deploy-op-sepolia
 */
contract DeployTestnet is DeployOmnibusBase {
  function label() internal pure override returns (string memory) {
    return DeployConstants.TESTNET_LABEL;
  }

  function allowedChains() internal pure override returns (uint256[] memory) {
    return DeployConstants.testnetChains();
  }

  function family() internal pure override returns (string memory) {
    return 'testnet';
  }
}
