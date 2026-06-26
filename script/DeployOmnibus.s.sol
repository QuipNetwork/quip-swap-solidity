// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Omnibus} from '../src/Omnibus.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';
import {ICreateX} from 'pcaversaccio-createx-1.0.0/src/ICreateX.sol';

/// @title DeployOmnibus
/// @notice Production deployment script for Omnibus using CreateX CREATE3
contract DeployOmnibus is Script {
  /// @notice CreateX factory address (same on all chains)
  ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

  /// @notice Salt suffix for Omnibus deployment
  bytes11 public constant SALT_SUFFIX_OMNIBUS = bytes11(keccak256('quip.network.Omnibus.v1'));

  /// @notice Owner address for the Omnibus contract
  address public constant OMNIBUS_OWNER = 0xc68B64770Da7914DEb0EF238b048a0Bf3B5f6A26;

  /// @notice Computes the RAW (pre-guard) CreateX salt for a deployment.
  /// @dev Raw salt format: deployer (20 bytes) + 0x00 (1 byte) + suffix (11 bytes).
  /// `deployCreate3` guards this salt internally, and the on-chain address derives
  /// from the GUARDED salt — so to predict the address via `computeCreate3Address`
  /// (which does NOT guard) the caller must guard it first.
  /// @param deployer The deployer address embedded in the salt (permissioned deploy)
  /// @param suffix The 11-byte salt suffix
  /// @return The 32-byte raw (pre-guard) salt
  function _computeRawSalt(address deployer, bytes11 suffix) internal pure returns (bytes32) {
    return bytes32(abi.encodePacked(deployer, bytes1(0x00), suffix));
  }

  function run() external {
    uint256 deployerPk = vm.envUint('DEPLOYER_PK');
    address deployer = vm.addr(deployerPk);

    console.log('Deployer:', deployer);
    console.log('Chain ID:', block.chainid);

    // Constructor args (config, not secrets). Owner falls back to the constant;
    // the factory must be set — Omnibus reverts ZeroQuipFactory on a zero factory.
    address owner = vm.envOr('OMNIBUS_OWNER', OMNIBUS_OWNER);
    address quipFactory = vm.envOr('QUIP_FACTORY', address(0));
    require(quipFactory != address(0), 'QUIP_FACTORY must be set (Omnibus reverts on zero factory)');

    // Raw salt — what deployCreate3 takes; it guards internally.
    bytes32 rawSalt = _computeRawSalt(deployer, SALT_SUFFIX_OMNIBUS);

    // Guarded salt — what CreateX actually derives the address from. For our salt
    // (first 20 bytes == msg.sender, 21st byte == 0x00) CreateX `_guard` computes
    // _efficientHash(bytes32(uint160(msg.sender)), salt), byte-identical to
    // keccak256(abi.encode(deployer, rawSalt)). computeCreate3Address does NOT
    // guard, so the prediction must use the guarded salt.
    bytes32 guardedSalt = keccak256(abi.encode(deployer, rawSalt));
    address expectedOmnibus = CREATEX.computeCreate3Address(guardedSalt, address(CREATEX));

    console.log('Expected Omnibus address:', expectedOmnibus);

    // Check if already deployed
    if (expectedOmnibus.code.length > 0) {
      console.log('Omnibus already deployed at expected address');
      return;
    }

    vm.startBroadcast(deployerPk);

    // Deploy Omnibus via CreateX CREATE3 (pass the RAW salt — deployCreate3 guards it).
    bytes memory omnibusInitCode = abi.encodePacked(type(Omnibus).creationCode, abi.encode(owner, quipFactory));
    address omnibus = CREATEX.deployCreate3(rawSalt, omnibusInitCode);

    vm.stopBroadcast();

    console.log('Omnibus deployed at:', omnibus);
    require(omnibus == expectedOmnibus, 'Address mismatch');
  }
}
