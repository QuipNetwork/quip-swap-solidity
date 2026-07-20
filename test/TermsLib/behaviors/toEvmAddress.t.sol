// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {TermsLib} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib toEvmAddress Tests
/// @dev Tests for TermsLib.toEvmAddress — narrowing bytes32 identifiers (EVM
///      addresses in the LOW 20 bytes) back to address; any of the upper 12
///      bytes set marks a foreign-chain identifier and must revert
contract TermsLib_toEvmAddress is TermsLibTest {
  // ============ Success Cases ============

  function test_toEvmAddress_zero() public view {
    assertEq(harness.exposed_toEvmAddress(bytes32(0)), address(0));
  }

  function test_toEvmAddress_maxEvmAddress() public view {
    // the highest narrowable value: all 160 address bits set, upper 96 clear
    bytes32 max = bytes32(uint256(type(uint160).max));
    assertEq(harness.exposed_toEvmAddress(max), address(type(uint160).max));
  }

  function testFuzz_toEvmAddress_roundTrip(address addr) public view {
    assertEq(harness.exposed_toEvmAddress(_b32(addr)), addr);
  }

  // ============ Revert Cases ============

  function test_toEvmAddress_revertsWhen_lowestForeignBitSet() public {
    // bit 160 is the first bit outside an EVM address
    bytes32 value = bytes32(uint256(1) << 160);
    vm.expectRevert(abi.encodeWithSelector(TermsLib.NotEvmAddress.selector, value));
    harness.exposed_toEvmAddress(value);
  }

  function test_toEvmAddress_revertsWhen_solanaPubkey() public {
    vm.expectRevert(abi.encodeWithSelector(TermsLib.NotEvmAddress.selector, SOLANA_PUBKEY));
    harness.exposed_toEvmAddress(SOLANA_PUBKEY);
  }

  function testFuzz_toEvmAddress_revertsWhen_upperBitsSet(uint256 value) public {
    vm.assume(value >> 160 != 0);
    vm.expectRevert(abi.encodeWithSelector(TermsLib.NotEvmAddress.selector, bytes32(value)));
    harness.exposed_toEvmAddress(bytes32(value));
  }
}
