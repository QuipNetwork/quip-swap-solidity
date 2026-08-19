// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Constants} from '../../script/Constants.sol';

/// @title Constants Base Test
/// @dev Base contract for testing the deployment salt math in `script/Constants.sol`.
///
///      Every assertion in this suite ultimately anchors to ONE fact: the live
///      Omnibus on Base Sepolia (84532), deployed through the canonical CreateX
///      factory by the ops EOA at the salt entropy below. Those four literals
///      are transcribed from the chain, not from the library, so if anyone
///      changes the salt composition the suite fails against reality rather
///      than agreeing with itself.
///
///      This is what makes the address a tested invariant instead of a
///      convention: `sdk/src/deployments.json` and `sdk/src/deployments.ts` ship
///      LIVE_OMNIBUS to every SDK consumer, and it is already occupied
///      on-chain. It cannot move.
contract ConstantsTest is Test {
  // ============ Live on-chain anchors (Base Sepolia, chain id 84532) ============

  /// @dev The deployed Omnibus. Also the `omnibus` of every current row in
  ///      `sdk/src/deployments.json` — they all still share one salt label.
  address public constant LIVE_OMNIBUS = 0xf780Fc9C066D824bFF85758E381A3919B1817f09;

  /// @dev The raw salt in the deployment transaction's `deployCreate3` calldata:
  ///      20-byte deployer ‖ 0x00 ‖ 11-byte entropy.
  bytes32 public constant LIVE_RAW_SALT = 0xc68b64770da7914deb0ef238b048a0bf3b5f6a260035932c1cb05b05751c5da2;

  /// @dev The guarded salt CreateX derived from it and fed to CREATE3.
  bytes32 public constant LIVE_GUARDED_SALT = 0x320d32719344a6801119cc535b8acada9f02ba39034b1b4440f460dcf3973912;

  /// @dev The intermediate CREATE2 proxy that CREATEd the Omnibus at nonce 1.
  address public constant LIVE_PROXY = 0x337d2CeA9e2895b364F3bc0DA1f4C28a12e94773;

  /// @dev The salt entropy label, spelled out. `Constants` stores only the
  ///      hash's leading 11 bytes, so without this the string itself is
  ///      untested and a typo would be invisible.
  string public constant SALT_LABEL = 'QUIP:Omnibus:v1.0.0-alpha.2';

  // ============ Setup assertions ============

  /// @dev Pins the four compiled-in constants. These are the only inputs to the
  ///      Omnibus address, so this test is the tripwire on all of them.
  function test_setUp() public pure virtual {
    assertEq(Constants.CREATEX, 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed, 'CreateX singleton changed');
    assertEq(Constants.DEPLOYER, 0xc68B64770Da7914DEb0EF238b048a0Bf3B5f6A26, 'DEPLOYER changed');
    assertEq(
      Constants.saltEntropy(SALT_LABEL), bytes11(keccak256(bytes(SALT_LABEL))), 'salt entropy does not match its label'
    );
    // The entropy is the leading 11 bytes of the label hash, and the raw salt's
    // trailing 11 bytes are that entropy — assert against the live salt so the
    // label is pinned to the chain, not just to itself.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes11 liveEntropy = bytes11(uint88(uint256(LIVE_RAW_SALT))); // intentional low-11-byte decode
    assertEq(Constants.saltEntropy(SALT_LABEL), liveEntropy, 'salt entropy does not match live salt');
  }
}
