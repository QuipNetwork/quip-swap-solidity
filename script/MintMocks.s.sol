// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Script, console} from 'forge-std-1.14.0/Script.sol';

import {ERC20Mock} from '../test/mocks/ERC20Mock.sol';
import {ERC721Mock} from '../test/mocks/ERC721Mock.sol';
import {ERC1155Mock} from '../test/mocks/ERC1155Mock.sol';

/// @title Mint Mock Tokens
/// @notice Mints mock tokens to specified addresses
///
/// Required environment variable:
///   DEPLOYER_PK - Private key for minting
///
/// Usage examples:
///   # Mint ERC20 (1000 tokens with 18 decimals)
///   forge script script/MintMocks.s.sol -s "mintERC20(address,address,uint256)" \
///     <ERC20_CONTRACT> <RECIPIENT> 1000000000000000000000 --rpc-url $RPC_URL --broadcast
///
///   # Mint ERC721 (token ID 1)
///   forge script script/MintMocks.s.sol -s "mintERC721(address,address,uint256)" \
///     <ERC721_CONTRACT> <RECIPIENT> 1 --rpc-url $RPC_URL --broadcast
///
///   # Mint ERC1155 (100 of token ID 1)
///   forge script script/MintMocks.s.sol -s "mintERC1155(address,address,uint256,uint256)" \
///     <ERC1155_CONTRACT> <RECIPIENT> 1 100 --rpc-url $RPC_URL --broadcast
contract MintMocks is Script {
  /// @notice Mint ERC20 tokens
  /// @param token The ERC20Mock contract address
  /// @param recipient The address to receive tokens
  /// @param amount The amount to mint (in wei, e.g., 1000e18 for 1000 tokens)
  function mintERC20(address token, address recipient, uint256 amount) external {
    uint256 deployerPk = vm.envUint('DEPLOYER_PK');

    vm.startBroadcast(deployerPk);
    ERC20Mock(token).mint(recipient, amount);
    vm.stopBroadcast();

    console.log('ERC20 minted:');
    console.log('  Token:', token);
    console.log('  Recipient:', recipient);
    console.log('  Amount:', amount);
  }

  /// @notice Mint ERC721 token
  /// @param token The ERC721Mock contract address
  /// @param recipient The address to receive the NFT
  /// @param tokenId The token ID to mint
  function mintERC721(address token, address recipient, uint256 tokenId) external {
    uint256 deployerPk = vm.envUint('DEPLOYER_PK');

    vm.startBroadcast(deployerPk);
    ERC721Mock(token).mint(recipient, tokenId);
    vm.stopBroadcast();

    console.log('ERC721 minted:');
    console.log('  Token:', token);
    console.log('  Recipient:', recipient);
    console.log('  Token ID:', tokenId);
  }

  /// @notice Mint ERC1155 tokens
  /// @param token The ERC1155Mock contract address
  /// @param recipient The address to receive tokens
  /// @param tokenId The token ID to mint
  /// @param amount The amount to mint
  function mintERC1155(address token, address recipient, uint256 tokenId, uint256 amount) external {
    uint256 deployerPk = vm.envUint('DEPLOYER_PK');

    vm.startBroadcast(deployerPk);
    ERC1155Mock(token).mint(recipient, tokenId, amount, '');
    vm.stopBroadcast();

    console.log('ERC1155 minted:');
    console.log('  Token:', token);
    console.log('  Recipient:', recipient);
    console.log('  Token ID:', tokenId);
    console.log('  Amount:', amount);
  }
}
