// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

/**
 * @title SaltRef
 * @dev An INDEPENDENT reference implementation of CreateX's salt guarding and
 *      CREATE3 address derivation, for tests only.
 *
 *      This deliberately does NOT reuse `script/Constants.sol` or solady's
 *      `CREATE3`. A test that computes the expected value with the same code it
 *      is testing proves nothing: it would still pass if both were wrong the
 *      same way. So the layout is built with bit shifts rather than
 *      `abi.encodePacked`, the proxy initcode hash is derived from the literal
 *      initcode rather than imported, and CREATE2 + the nonce-1 CREATE are
 *      written out longhand.
 *
 *      It is also deliberately POLICY-FREE and parameterized where `Constants`
 *      is hardcoded: `create3` applies no guard at all, so the known-answer test
 *      built on it stays valid if the guard mode ever changes, and the
 *      wrong-deployer cases the fork test needs can be expressed without adding
 *      a parameterized escape hatch to the production library.
 *
 *      Reference: https://github.com/pcaversaccio/createx (`_guard`, `_parseSalt`).
 */
library SaltRef {
  /// @dev The CREATE3 proxy initcode. CreateX and solady both use this one:
  ///      it returns the 1-byte runtime `0xf3` … in effect a contract whose only
  ///      behaviour is to CREATE its calldata. Kept as a literal so a change in
  ///      either dependency shows up as a test failure.
  bytes internal constant PROXY_INITCODE = hex'67363d3d37363d34f03d5260086018f3';

  /// @dev Byte 20 of a permissioned salt: no cross-chain redeploy protection,
  ///      i.e. `block.chainid` stays out of the guard and the address is
  ///      chain-invariant.
  bytes1 internal constant FLAG_NO_REDEPLOY_PROTECTION = 0x00;

  /// @dev Byte 20 = 0x01: CreateX mixes `block.chainid` into the guard, making
  ///      the address per-chain. Present only so tests can assert we do NOT use it.
  bytes1 internal constant FLAG_CHAIN_SCOPED = 0x01;

  /// @notice Composes a raw CreateX salt: [20-byte deployer][1-byte flag][11-byte entropy].
  /// @dev Built by shifting rather than `abi.encodePacked` so this is a genuinely
  ///      independent encoding of the same layout.
  function rawSalt(address deployer, bytes1 flag, bytes11 entropy) internal pure returns (bytes32) {
    return bytes32((uint256(uint160(deployer)) << 96) | (uint256(uint8(flag)) << 88) | uint256(uint88(entropy)));
  }

  /// @notice CreateX's guard for SenderBytes.MsgSender + RedeployProtectionFlag.False.
  /// @dev `keccak256(abi.encode(sender, salt))` — the left-padded 32-byte sender
  ///      followed by the 32-byte salt.
  function permissionedGuard(address sender, bytes32 salt) internal pure returns (bytes32) {
    return keccak256(bytes.concat(bytes32(uint256(uint160(sender))), salt));
  }

  /// @notice CreateX's guard for SenderBytes.Random + RedeployProtectionFlag.False —
  ///         the branch a FOREIGN caller of a permissioned salt falls through to.
  /// @dev This is what makes the squat fail: the same salt in someone else's hands
  ///      derives a completely different, and precisely predictable, address.
  function permissionlessGuard(bytes32 salt) internal pure returns (bytes32) {
    return keccak256(abi.encode(salt));
  }

  /// @notice CreateX's guard for SenderBytes.MsgSender + RedeployProtectionFlag.True.
  /// @dev Only used to prove the 0x01 flag byte would produce a per-chain address.
  function chainScopedGuard(address sender, bytes32 salt) internal view returns (bytes32) {
    return keccak256(abi.encode(sender, block.chainid, salt));
  }

  /// @notice The CREATE2 proxy address for an ALREADY-GUARDED salt.
  function proxyAddress(bytes32 guarded, address factory) internal pure returns (address) {
    return
      address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, guarded, keccak256(PROXY_INITCODE))))));
  }

  /// @notice Full CREATE3 derivation for an ALREADY-GUARDED salt: the CREATE2
  ///         proxy, then that proxy's nonce-1 CREATE child.
  /// @dev The child is RLP([proxy, 1]) = 0xd6 0x94 ‖ proxy ‖ 0x01, hashed and
  ///      truncated to 20 bytes. Applies NO guard — pure address math.
  function create3(bytes32 guarded, address factory) internal pure returns (address) {
    address proxy = proxyAddress(guarded, factory);
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), proxy, bytes1(0x01))))));
  }
}
