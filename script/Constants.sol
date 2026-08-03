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
 *      its address is a function of (CreateX, DEPLOYER, salt) — identical on
 *      every chain, and independent of constructor args. The salt is
 *      CreateX-permissioned: only DEPLOYER can ever claim the address on any
 *      chain (no CREATE3 address-squatting).
 *
 *      Every value here is compiled in, so derivation is `pure`: predicting the
 *      address needs no RPC and no environment. See the DEPLOYER note for why
 *      that is a safety property and not just a convenience.
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
  ///         permissioned salt).
  ///
  ///         This label is a SALT version, NOT a release gate. It is
  ///         deliberately the SAME on every chain — testnet and mainnet alike —
  ///         because that is what gives the Omnibus one address everywhere.
  ///         Bumping it to mark a promotion to mainnet would move the address
  ///         on the new chain only, splitting the deployment across two
  ///         addresses and breaking the single-canonical-address model that
  ///         `sdk/src/deployments.ts` is built on.
  ///
  ///         Bump it ONLY for an intentional redeploy of every chain (the
  ///         recovery path for a mistaken or unwanted address). Each
  ///         (DEPLOYER, entropy) pair maps to a distinct, permanently-consumed
  ///         address, so a bump abandons the old one everywhere.
  bytes11 internal constant OMNIBUS_SALT_ENTROPY = bytes11(keccak256('QUIP:Omnibus:v1.0.0-alpha.2'));

  /// @notice The raw CreateX salt for the Omnibus singleton, permissioned to
  ///         DEPLOYER: 20-byte EOA ‖ 0x00 (no cross-chain redeploy protection —
  ///         the address must be claimable on every chain) ‖ 11-byte version
  ///         entropy.
  /// @dev The 0x00 flag byte is what keeps `block.chainid` out of CreateX's
  ///      guard. Setting it to 0x01 would silently make the address per-chain.
  function omnibusSalt() internal pure returns (bytes32) {
    return bytes32(abi.encodePacked(DEPLOYER, hex'00', OMNIBUS_SALT_ENTROPY));
  }

  /// @notice The salt CreateX actually feeds to CREATE3. For a sender-prefixed
  ///         salt with the 0x00 flag byte, CreateX takes the
  ///         SenderBytes.MsgSender + RedeployProtectionFlag.False path:
  ///         `keccak256(abi.encodePacked(bytes32(uint256(uint160(sender))), salt))`.
  /// @dev Any OTHER sender passing this same salt fails the prefix match and
  ///      falls to the permissionless branch, `keccak256(abi.encode(salt))`,
  ///      which derives an unrelated address. That is the anti-squat property.
  function guardedSalt() internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(bytes32(uint256(uint160(DEPLOYER))), omnibusSalt()));
  }

  /// @notice The Omnibus address — pure offline math, no inputs, no RPC.
  ///         CreateX's CREATE3 proxy is the standard one solady uses, so
  ///         solady's predictor applies with CreateX as the deployer.
  function predictOmnibus() internal pure returns (address) {
    return CREATE3.predictDeterministicAddress(guardedSalt(), CREATEX);
  }
}
