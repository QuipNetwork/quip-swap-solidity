// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Script, console} from 'forge-std-1.14.0/Script.sol';

/// @title VerifyOmnibus
/// @notice Checks that the `omnibusAddress` in an address-json file equals the
/// Create3 address `DeployOmnibus` would deploy for the deployer in `DEPLOYER_PK`.
/// Pure offline math — no RPC, no on-chain calls, no getters. The Create3 address
/// is fully determined by `(deployer, salt, CreateX address)`, all known locally,
/// so the CreateX salt-guard + two-hop CREATE3 derivation is replicated here with
/// forge-std cheatcodes.
/// @dev File defaults to `sdk/src/address.json`; override with the `ADDRESS_JSON`
/// env var (absolute or repo-root-relative). The file must contain an
/// `omnibusAddress` field; the deployer is derived from `DEPLOYER_PK` (address
/// only — no broadcast).
///
/// Usage:
///   make verify-omnibus
///   make verify-omnibus FILE=path/to/other.json
///   forge script script/VerifyOmnibus.s.sol:VerifyOmnibus -v
///   ADDRESS_JSON=path/to/other.json forge script script/VerifyOmnibus.s.sol:VerifyOmnibus -v
contract VerifyOmnibus is Script {
  /// @notice CreateX factory address (same on all chains).
  address public constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

  /// @notice Salt suffix for the Omnibus deployment (matches `DeployOmnibus`).
  bytes11 public constant SALT_SUFFIX_OMNIBUS = bytes11(keccak256('quip.network.Omnibus.v1'));

  /// @notice Hash of the CreateX CREATE3 proxy initcode (`0x67363d3d37363d34f03d5260086018f3`),
  /// equal to CreateX's own hardcoded `0x21c3…7c1f`.
  bytes32 public constant PROXY_INITCODE_HASH = keccak256(hex'67363d3d37363d34f03d5260086018f3');

  function run() external view {
    // 1. read omnibusAddress from the address-json file. Default sdk/src/address.json;
    //    override via ADDRESS_JSON (absolute or repo-root-relative, passed as-is —
    //    do NOT prepend projectRoot to the override).
    string memory defaultPath = string.concat(vm.projectRoot(), '/sdk/src/address.json');
    string memory path = vm.envOr('ADDRESS_JSON', defaultPath);
    string memory json = vm.readFile(path);
    address fromJson = vm.parseJsonAddress(json, '.omnibusAddress');
    console.log('address.json path', path);

    // 2. compute the predicted Create3 address LOCALLY (no chain).
    //    Deployer comes from DEPLOYER_PK exactly like DeployOmnibus.run() — only
    //    its address is needed; no broadcast, no signing.
    address deployer = vm.addr(vm.envUint('DEPLOYER_PK'));

    // Raw guarded salt, identical to DeployOmnibus._computeGuardedSalt:
    // deployer (20 bytes) ++ 0x00 (1 byte) ++ suffix (11 bytes).
    bytes32 rawSalt = bytes32(abi.encodePacked(deployer, bytes1(0x00), SALT_SUFFIX_OMNIBUS));

    // CreateX re-guards the salt. Since the deploy broadcasts as `deployer`,
    // msg.sender == deployer and salt[20] == 0x00 → CreateX `_guard` takes the
    // (MsgSender, RedeployProtection.False) branch:
    //   _efficientHash(bytes32(uint160(msg.sender)), salt)
    // which is byte-identical to keccak256(abi.encode(deployer, rawSalt)).
    bytes32 guardedSalt = keccak256(abi.encode(deployer, rawSalt));

    // CREATE3 hop 1: CreateX CREATE2-deploys the proxy with the fixed proxy initcode.
    address proxy = vm.computeCreate2Address(guardedSalt, PROXY_INITCODE_HASH, CREATEX);
    // CREATE3 hop 2: the proxy CREATEs the contract at nonce 1.
    address predicted = vm.computeCreateAddress(proxy, 1);

    // 3. compare
    console.log('deployer    ', deployer);
    console.log('predicted   ', predicted);
    console.log('address.json', fromJson);

    if (fromJson == address(0)) {
      console.log('address.json is placeholder (zero) - nothing to compare');
      return;
    }
    require(fromJson == predicted, 'VerifyOmnibus: address.json does not match predicted address');
    console.log('OK - address.json matches predicted');
  }
}
