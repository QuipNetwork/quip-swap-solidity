// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {CREATE3} from 'solady-0.1.26/utils/CREATE3.sol';

/**
 * @title Constants
 * @dev Shared deployment constants used across the deploy/verify scripts.
 *      Single source of truth so DeployOmnibus, VerifyOmnibus and
 *      ActivateVerifier can never drift on the salt math (which would change
 *      the deterministic address).
 *
 *      Omnibus deploys through the canonical CreateX factory via CREATE3, so
 *      its address is a function of (CreateX, DEPLOYER, salt) — independent of
 *      constructor args. The salt is CreateX-permissioned: only DEPLOYER can
 *      ever claim the address on any chain (no CREATE3 address-squatting).
 *
 *      THE VERSION LABEL IS AN ARGUMENT, NOT A CONSTANT. It used to be compiled
 *      in, on the premise that one label on every chain gives the Omnibus one
 *      address everywhere. That premise died the moment a chain needed a
 *      redeploy the others did not: testnets churn, mainnet does not. The label
 *      now lives per-chain in the deployment registry (`sdk/src/deployments.json`,
 *      read by `Deployments.sol`), so a testnet redeploy is a data edit rather
 *      than a source edit + rebuild + version bump.
 *
 *      DEPLOYER stays compiled in. It is the gate that makes a wrong signer a
 *      loud failure instead of a silent deploy to an unadvertised address, and
 *      unlike the label it does not churn. See its note below.
 *
 *      Derivation is still `pure`: given a label, predicting the address needs
 *      no RPC and no environment.
 */
library Constants {
  /// @notice The canonical CreateX factory, pre-deployed at this address on
  ///         essentially every EVM chain.
  address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

  /// @notice The ops EOA every Omnibus address is permissioned to. COMPILED IN,
  ///         deliberately not configurable: the CreateX salt is permissioned to
  ///         this EOA, so the EOA *is* part of the address.
  ///
  ///         This matters because a wrong signer does not revert inside CreateX.
  ///         It composes a salt permissioned to *itself*, takes the same branch,
  ///         and deploys successfully at a DIFFERENT, unadvertised address. Were
  ///         the deployer read from the environment, the prediction would move
  ///         with it and every post-deploy `deployed == expected` check would
  ///         still pass — a silent deploy to the wrong address. Hardcoding turns
  ///         that into a loud pre-broadcast failure (see DeployOmnibus).
  ///
  ///         Changing this value changes the Omnibus address on every chain not
  ///         yet deployed to. Do not edit it to match a key you happen to hold.
  address internal constant DEPLOYER = 0xc68B64770Da7914DEb0EF238b048a0Bf3B5f6A26;

  /// @notice Version entropy for the Omnibus salt (last 11 bytes of the
  ///         permissioned salt), derived from a human-readable version label.
  ///
  /// @dev The label is the source of truth and the entropy is derived from it,
  ///      never the other way round: a registry row records the string, and
  ///      every consumer re-derives. That keeps a hand-edited row checkable.
  ///
  ///      Each (DEPLOYER, label) pair maps to a distinct, permanently-consumed
  ///      address. Reusing a label on a chain that already has it deployed is a
  ///      no-op at best; a NEW label is what moves the address, which is the
  ///      recovery path for a mistaken or unwanted deployment.
  ///
  /// @param versionLabel the deployment's version string, e.g.
  ///        'QUIP:Omnibus:v1.0.0-beta.2'
  function saltEntropy(string memory versionLabel) internal pure returns (bytes11) {
    return bytes11(keccak256(bytes(versionLabel)));
  }

  /// @notice The raw CreateX salt for an Omnibus deployment, permissioned to
  ///         DEPLOYER: 20-byte EOA ‖ 0x00 (no cross-chain redeploy protection —
  ///         the address must be claimable on every chain) ‖ 11-byte version
  ///         entropy.
  /// @dev The 0x00 flag byte is what keeps `block.chainid` out of CreateX's
  ///      guard. Setting it to 0x01 would silently make the address per-chain.
  function omnibusSalt(string memory versionLabel) internal pure returns (bytes32) {
    return bytes32(abi.encodePacked(DEPLOYER, hex'00', saltEntropy(versionLabel)));
  }

  /// @notice The salt CreateX actually feeds to CREATE3. For a sender-prefixed
  ///         salt with the 0x00 flag byte, CreateX takes the
  ///         SenderBytes.MsgSender + RedeployProtectionFlag.False path:
  ///         `keccak256(abi.encodePacked(bytes32(uint256(uint160(sender))), salt))`.
  /// @dev Any OTHER sender passing this same salt fails the prefix match and
  ///      falls to the permissionless branch, `keccak256(abi.encode(salt))`,
  ///      which derives an unrelated address. That is the anti-squat property.
  function guardedSalt(string memory versionLabel) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(bytes32(uint256(uint160(DEPLOYER))), omnibusSalt(versionLabel)));
  }

  /// @notice The Omnibus address for a version label — pure offline math, no
  ///         RPC. CreateX's CREATE3 proxy is the standard one solady uses, so
  ///         solady's predictor applies with CreateX as the deployer.
  function predictOmnibus(string memory versionLabel) internal pure returns (address) {
    return CREATE3.predictDeterministicAddress(guardedSalt(versionLabel), CREATEX);
  }
}
