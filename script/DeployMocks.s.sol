// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Script, console} from 'forge-std-1.14.0/Script.sol';

import {ERC1155Mock} from '../test/mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../test/mocks/ERC20Mock.sol';
import {ERC721Mock} from '../test/mocks/ERC721Mock.sol';

/// @title Deploy Mock Tokens
/// @notice Deploys mock ERC20, ERC721, and ERC1155 tokens for testing
/// @dev Run with: forge script script/DeployMocks.s.sol --rpc-url $RPC_URL --broadcast
///
/// Required environment variables:
///   DEPLOYER_PK - Private key for deployment
contract DeployMocks is Script {
  function run() external {
    uint256 deployerPk = vm.envUint('DEPLOYER_PK');

    vm.startBroadcast(deployerPk);

    ERC20Mock erc20 = new ERC20Mock('Mock Token', 'MOCK', 18);
    ERC721Mock erc721 = new ERC721Mock('Mock NFT', 'MNFT');
    ERC1155Mock erc1155 = new ERC1155Mock('https://example.com/token/{id}.json');

    vm.stopBroadcast();

    console.log('=== Mock Tokens Deployed ===');
    console.log('ERC20Mock:', address(erc20));
    console.log('ERC721Mock:', address(erc721));
    console.log('ERC1155Mock:', address(erc1155));
  }
}
