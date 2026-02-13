// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Script, console} from 'forge-std-1.14.0/Script.sol';

import {Quip} from '../src/Quip.sol';
import {QuipPortal} from '../src/QuipPortal.sol';
import {ERC1155Mock} from '../test/mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../test/mocks/ERC20Mock.sol';
import {ERC721Mock} from '../test/mocks/ERC721Mock.sol';

/// @title Deploy Helper
/// @notice Deploys all QUIP contracts, mocks, and mints to test addresses in one script
/// @dev Run with: forge script script/DeployHelper.s.sol --rpc-url $RPC_URL --broadcast
///
/// Required environment variables:
///   DEPLOYER_PK - Private key for deployment
///   PORTAL_ADMIN - Admin address for fee management
///
/// For local anvil testing:
///   forge script script/DeployHelper.s.sol --rpc-url http://localhost:8545 --broadcast
///
/// For testnets:
///   forge script script/DeployHelper.s.sol --rpc-url $RPC_URL --broadcast --verify
contract DeployHelper is Script {
  // ============ Configuration ============

  uint256 public constant MAX_FEE = 1 ether;
  uint256 public constant CREATION_FEE = 0.01 ether;

  // Default mint amounts
  uint256 public constant ERC20_MINT_AMOUNT = 1_000_000 ether; // 1M tokens with 18 decimals
  uint256 public constant ERC721_MINT_COUNT = 3; // 3 NFTs per address
  uint256 public constant ERC1155_MINT_AMOUNT = 1_000; // 1000 units per token ID
  uint256 public constant NATIVE_FUND_AMOUNT = 100 ether; // 100 ETH per address

  // ERC1155 token IDs to mint
  uint256 public constant ERC1155_TOKEN_ID_1 = 1;
  uint256 public constant ERC1155_TOKEN_ID_2 = 2;

  // ============ Test Addresses ============
  // Add addresses here to receive minted tokens

  function _getTestAddresses() internal pure returns (address[] memory) {
    address[] memory addresses = new address[](2);
    // TODO: Replace with actual test addresses
    addresses[0] = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // Anvil default account 0
    addresses[1] = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // Anvil default account 1
    return addresses;
  }

  // ============ Main Entry Point ============

  function run() external {
    uint256 deployerPk = vm.envUint('DEPLOYER_PK');
    address portalAdmin = vm.envAddress('PORTAL_ADMIN');
    address deployer = vm.addr(deployerPk);

    console.log('=== Deploy Helper ===');
    console.log('Deployer:', deployer);
    console.log('Admin:', portalAdmin);
    console.log('Chain ID:', block.chainid);

    vm.startBroadcast(deployerPk);

    // Deploy QUIP contracts
    (Quip quipImpl, QuipPortal portal) = _deployQuipContracts(portalAdmin);

    // Deploy mock tokens
    (ERC20Mock erc20, ERC721Mock erc721, ERC1155Mock erc1155) = _deployMocks();

    // Get test addresses and mint to each
    address[] memory testAddresses = _getTestAddresses();
    _mintToAddresses(testAddresses, erc20, erc721, erc1155);

    vm.stopBroadcast();

    // Print summary
    _printSummary(address(quipImpl), address(portal), address(erc20), address(erc721), address(erc1155), testAddresses);
  }

  // ============ Internal Functions ============

  function _deployQuipContracts(address admin) internal returns (Quip quipImpl, QuipPortal portal) {
    console.log('');
    console.log('--- Deploying QUIP Contracts ---');

    quipImpl = new Quip();
    console.log('Quip implementation:', address(quipImpl));

    portal = new QuipPortal(admin, address(quipImpl), MAX_FEE, CREATION_FEE);
    console.log('QuipPortal:', address(portal));
  }

  function _deployMocks() internal returns (ERC20Mock erc20, ERC721Mock erc721, ERC1155Mock erc1155) {
    console.log('');
    console.log('--- Deploying Mock Tokens ---');

    erc20 = new ERC20Mock('Mock Token', 'MOCK', 18);
    console.log('ERC20Mock:', address(erc20));

    erc721 = new ERC721Mock('Mock NFT', 'MNFT');
    console.log('ERC721Mock:', address(erc721));

    erc1155 = new ERC1155Mock('https://example.com/token/{id}.json');
    console.log('ERC1155Mock:', address(erc1155));
  }

  function _mintToAddresses(
    address[] memory addresses,
    ERC20Mock erc20,
    ERC721Mock erc721,
    ERC1155Mock erc1155
  ) internal {
    console.log('');
    console.log('--- Minting to Test Addresses ---');

    bool isLocal = block.chainid == 31337;

    for (uint256 i = 0; i < addresses.length; i++) {
      address recipient = addresses[i];
      console.log('');
      console.log('Minting to:', recipient);

      // Fund with native ETH
      if (isLocal) {
        // On local anvil, use vm.deal
        vm.deal(recipient, NATIVE_FUND_AMOUNT);
        console.log('  Funded (vm.deal):', NATIVE_FUND_AMOUNT);
      } else {
        // On testnets, transfer from deployer
        (bool success,) = recipient.call{value: NATIVE_FUND_AMOUNT}('');
        require(success, 'ETH transfer failed');
        console.log('  Funded (transfer):', NATIVE_FUND_AMOUNT);
      }

      // Mint ERC20
      erc20.mint(recipient, ERC20_MINT_AMOUNT);
      console.log('  ERC20:', ERC20_MINT_AMOUNT);

      // Mint ERC721 (3 NFTs each)
      for (uint256 j = 0; j < ERC721_MINT_COUNT; j++) {
        erc721.mint(recipient);
      }
      console.log('  ERC721:', ERC721_MINT_COUNT, 'NFTs');

      // Mint ERC1155 (token IDs 1 and 2)
      erc1155.mint(recipient, ERC1155_TOKEN_ID_1, ERC1155_MINT_AMOUNT, '');
      erc1155.mint(recipient, ERC1155_TOKEN_ID_2, ERC1155_MINT_AMOUNT, '');
      console.log('  ERC1155: 1000 each of IDs 1 & 2');
    }
  }

  function _printSummary(
    address quipImpl,
    address portal,
    address erc20,
    address erc721,
    address erc1155,
    address[] memory testAddresses
  ) internal pure {
    console.log('');
    console.log('========================================');
    console.log('          DEPLOYMENT COMPLETE          ');
    console.log('========================================');
    console.log('');
    console.log('QUIP Contracts:');
    console.log('  Quip Implementation:', quipImpl);
    console.log('  QuipPortal:', portal);
    console.log('');
    console.log('Mock Tokens:');
    console.log('  ERC20Mock:', erc20);
    console.log('  ERC721Mock:', erc721);
    console.log('  ERC1155Mock:', erc1155);
    console.log('');
    console.log('Test Addresses Funded:');
    for (uint256 i = 0; i < testAddresses.length; i++) {
      console.log(' ', testAddresses[i]);
    }
    console.log('');
    console.log('Per Address:');
    console.log('  Native ETH: 100');
    console.log('  ERC20: 1,000,000');
    console.log('  ERC721: 3 NFTs');
    console.log('  ERC1155: 1,000 each of IDs 1 & 2');
  }
}
