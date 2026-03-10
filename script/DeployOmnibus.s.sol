// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Script, console} from 'forge-std-1.14.0/Script.sol';
import {ICreateX} from 'pcaversaccio-createx-1.0.0/src/ICreateX.sol';
import {Omnibus} from '../src/Omnibus.sol';

/// @title DeployOmnibus
/// @notice Production deployment script for Omnibus using CreateX CREATE3
contract DeployOmnibus is Script {
    /// @notice CreateX factory address (same on all chains)
    ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    /// @notice Salt suffix for Omnibus deployment
    bytes11 public constant SALT_SUFFIX_OMNIBUS = bytes11(keccak256('quip.network.Omnibus.v1'));

    /// @notice Owner address for the Omnibus contract
    address public constant OMNIBUS_OWNER = 0xc68B64770Da7914DEb0EF238b048a0Bf3B5f6A26;

    /// @notice Computes a guarded salt for CreateX deployment
    /// @dev Guarded salt format: deployer (20 bytes) + 0x00 (1 byte) + suffix (11 bytes)
    /// @param deployer The deployer address that will be guarded
    /// @param suffix The 11-byte salt suffix
    /// @return The 32-byte guarded salt
    function _computeGuardedSalt(address deployer, bytes11 suffix) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(deployer, bytes1(0x00), suffix));
    }

    function run() external {
        uint256 deployerPk = vm.envUint('DEPLOYER_PK');
        address deployer = vm.addr(deployerPk);

        console.log('Deployer:', deployer);
        console.log('Chain ID:', block.chainid);

        // Compute expected address
        bytes32 salt = _computeGuardedSalt(deployer, SALT_SUFFIX_OMNIBUS);
        address expectedOmnibus = CREATEX.computeCreate3Address(salt, address(CREATEX));

        console.log('Expected Omnibus address:', expectedOmnibus);

        // Check if already deployed
        if (expectedOmnibus.code.length > 0) {
            console.log('Omnibus already deployed at expected address');
            return;
        }

        vm.startBroadcast(deployerPk);

        // Deploy Omnibus via CreateX CREATE3
        bytes memory omnibusInitCode = abi.encodePacked(
            type(Omnibus).creationCode,
            abi.encode(OMNIBUS_OWNER)
        );
        address omnibus = CREATEX.deployCreate3(salt, omnibusInitCode);

        vm.stopBroadcast();

        console.log('Omnibus deployed at:', omnibus);
        require(omnibus == expectedOmnibus, 'Address mismatch');
    }
}
