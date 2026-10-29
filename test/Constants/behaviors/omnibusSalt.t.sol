// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Constants} from '../../../script/Constants.sol';
import {SaltRef} from '../../utils/SaltRef.sol';
import {ConstantsTest} from '../Constants.t.sol';

/// @title Constants omnibusSalt Tests
/// @dev Tests for the RAW CreateX salt layout: [20-byte DEPLOYER][1-byte 0x00][11-byte entropy].
///
///      The layout is not cosmetic — it is what selects CreateX's guard branch.
///      Bytes 0-19 matching msg.sender is what makes the salt permissioned;
///      byte 20 being 0x00 is what keeps block.chainid out of the guard and the
///      address chain-invariant. Get either wrong and CreateX does not revert,
///      it silently derives a different address.
contract Constants_omnibusSalt is ConstantsTest {
  // ============ Known-answer ============

  function test_omnibusSalt_matchesLiveRawSalt() public pure {
    assertEq(Constants.omnibusSalt(SALT_LABEL), LIVE_RAW_SALT, 'raw salt no longer matches the live deployment');
  }

  function test_omnibusSalt_matchesReferenceEncoding() public pure {
    assertEq(
      Constants.omnibusSalt(SALT_LABEL),
      SaltRef.rawSalt(Constants.DEPLOYER, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, Constants.saltEntropy(SALT_LABEL)),
      'abi.encodePacked layout disagrees with the shift-based reference'
    );
  }

  // ============ Layout invariants ============

  /// @dev Bytes 0-19 must equal DEPLOYER or CreateX drops to the permissionless
  ///      branch — the address stops being ours and becomes squattable.
  function test_omnibusSalt_hasDeployerPrefix() public pure {
    assertEq(
      address(bytes20(Constants.omnibusSalt(SALT_LABEL))), Constants.DEPLOYER, 'salt is not permissioned to DEPLOYER'
    );
  }

  /// @dev Byte 20 must be 0x00. A 0x01 here mixes block.chainid into the guard,
  ///      silently giving a DIFFERENT address on every chain.
  function test_omnibusSalt_hasZeroRedeployProtectionByte() public pure {
    assertEq(
      Constants.omnibusSalt(SALT_LABEL)[20], SaltRef.FLAG_NO_REDEPLOY_PROTECTION, 'redeploy-protection flag is not 0x00'
    );
  }

  function test_omnibusSalt_hasEntropySuffix() public pure {
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes11 suffix = bytes11(uint88(uint256(Constants.omnibusSalt(SALT_LABEL)))); // truncation IS the decode under test
    assertEq(suffix, Constants.saltEntropy(SALT_LABEL), 'entropy suffix mismatch');
  }

  // ============ Fuzz ============

  /// @dev The layout must round-trip for ANY deployer/entropy, not just ours —
  ///      otherwise the three assertions above could pass by coincidence on one
  ///      lucky value.
  function testFuzz_omnibusSalt_layoutRoundTrips(address deployer, bytes11 entropy) public pure {
    bytes32 salt = SaltRef.rawSalt(deployer, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, entropy);

    // forge-lint: disable-next-line(unsafe-typecast)
    address decodedDeployer = address(bytes20(salt)); // intentional high-20-byte decode
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes11 decodedEntropy = bytes11(uint88(uint256(salt))); // intentional low-11-byte decode

    assertEq(decodedDeployer, deployer, 'deployer prefix did not round-trip');
    assertEq(salt[20], SaltRef.FLAG_NO_REDEPLOY_PROTECTION, 'flag byte did not round-trip');
    assertEq(decodedEntropy, entropy, 'entropy suffix did not round-trip');
  }

  /// @dev The shift-based reference and abi.encodePacked must agree for every
  ///      input, not merely for the compiled-in one.
  function testFuzz_omnibusSalt_referenceMatchesPackedEncoding(address deployer, bytes11 entropy) public pure {
    assertEq(
      SaltRef.rawSalt(deployer, SaltRef.FLAG_NO_REDEPLOY_PROTECTION, entropy),
      bytes32(abi.encodePacked(deployer, hex'00', entropy)),
      'reference encoding diverges from abi.encodePacked'
    );
  }
}
