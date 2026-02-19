// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Script, console} from 'forge-std-1.14.0/Script.sol';
import {ICreateX} from 'pcaversaccio-createx-1.0.0/src/ICreateX.sol';

import {Quip} from '../src/Quip.sol';
import {QuipPortal} from '../src/QuipPortal.sol';
import {ERC1155Mock} from '../test/mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../test/mocks/ERC20Mock.sol';
import {ERC721Mock} from '../test/mocks/ERC721Mock.sol';

/// @title Deploy Helper
/// @notice Deploys all QUIP contracts, mocks, and mints to test addresses using CreateX
/// @dev Uses CREATE3 for truly chain-independent addresses (independent of constructor args)
///
/// Run with: forge script script/DeployHelper.s.sol --rpc-url $RPC_URL --broadcast
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
///
/// Deterministic Addresses (CREATE3):
///   Addresses depend ONLY on the CreateX factory address and the salt.
///   Constructor arguments do NOT affect the deployed address, allowing
///   different admins per chain while maintaining the same contract addresses.
contract DeployHelper is Script {
  // ============ CreateX Factory ============

  /// @notice CreateX factory deployed on 60+ chains at this address
  /// @dev See https://createx.rocks for full chain list
  ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

  // ============ Configuration ============

  uint256 public constant MAX_FEE = 1 ether;
  uint256 public constant CREATION_FEE = 1 wei;

  // Default mint amounts
  uint256 public constant ERC20_MINT_AMOUNT = 1_000_000 ether; // 1M tokens with 18 decimals
  uint256 public constant ERC721_MINT_COUNT = 3; // 3 NFTs per address
  uint256 public constant ERC1155_MINT_AMOUNT = 1_000; // 1000 units per token ID
  uint256 public constant NATIVE_FUND_AMOUNT = 100 ether; // 100 ETH per address
  uint256 public constant PUBLIC_TESTNET_NATIVE_FUND_AMOUNT = 0.000000001 ether; 

  // ERC1155 token IDs to mint
  uint256 public constant ERC1155_TOKEN_ID_1 = 1;
  uint256 public constant ERC1155_TOKEN_ID_2 = 2;

  // ============ Salt Suffixes ============
  // Using 11-byte suffixes that get combined with deployer address + flag for guarded salts
  // Salt format: deployer (20 bytes) + flag (1 byte) + suffix (11 bytes)
  // Flag 0x00 = same address on all chains (no cross-chain redeploy protection)

  bytes11 public constant SALT_SUFFIX_QUIP_IMPL = bytes11(keccak256('quip.network.QuipImpl.v1'));
  bytes11 public constant SALT_SUFFIX_QUIP_PORTAL = bytes11(keccak256('quip.network.QuipPortal.v1'));
  bytes11 public constant SALT_SUFFIX_ERC20_MOCK = bytes11(keccak256('quip.network.ERC20Mock.v1'));
  bytes11 public constant SALT_SUFFIX_ERC721_MOCK = bytes11(keccak256('quip.network.ERC721Mock.v1'));
  bytes11 public constant SALT_SUFFIX_ERC1155_MOCK = bytes11(keccak256('quip.network.ERC1155Mock.v1'));

  // ============ Test Addresses ============
  // Add addresses here to receive minted tokens

  function _getTestAddresses() internal pure returns (address[] memory) {
    address[] memory addresses = new address[](1);
    // TODO: Replace with actual test addresses
    addresses[0] = 0xc68B64770Da7914DEb0EF238b048a0Bf3B5f6A26; // Anvil default account 0
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
    console.log('CreateX Factory:', address(CREATEX));

    // Compute expected addresses before deployment
    console.log('');
    console.log('--- Expected Addresses ---');
    _printExpectedAddresses(deployer);

    vm.startBroadcast(deployerPk);

    // Deploy QUIP contracts via CREATE3 (deterministic)
    (address quipImpl, address portal) = _deployQuipContracts(deployer, portalAdmin);

    // Deploy mock tokens via CREATE3 (deterministic)
    (address erc20, address erc721, address erc1155) = _deployMocks(deployer);

    // Get test addresses and mint to each
    address[] memory testAddresses = _getTestAddresses();
    _mintToAddresses(testAddresses, ERC20Mock(erc20), ERC721Mock(erc721), ERC1155Mock(erc1155));

    vm.stopBroadcast();

    // Print summary
    _printSummary(quipImpl, portal, erc20, erc721, erc1155, testAddresses);
  }

  // ============ Salt Computation ============

  /// @notice Computes a guarded salt with deployer address in first 20 bytes
  /// @dev Salt format: deployer (20 bytes) + 0x00 (1 byte, no cross-chain protection) + suffix (11 bytes)
  ///      This prevents frontrunning while ensuring same addresses across all chains
  function _computeGuardedSalt(address deployer, bytes11 suffix) internal pure returns (bytes32) {
    return bytes32(abi.encodePacked(deployer, bytes1(0x00), suffix));
  }

  // ============ Address Computation ============

  /// @notice Prints expected addresses before deployment
  function _printExpectedAddresses(address deployer) internal pure {
    // Quip Implementation
    bytes32 saltQuipImpl = _computeGuardedSalt(deployer, SALT_SUFFIX_QUIP_IMPL);
    address expectedQuipImpl = CREATEX.computeCreate3Address(saltQuipImpl, address(CREATEX));
    console.log('Quip Implementation:', expectedQuipImpl);

    // QuipPortal
    bytes32 saltQuipPortal = _computeGuardedSalt(deployer, SALT_SUFFIX_QUIP_PORTAL);
    address expectedPortal = CREATEX.computeCreate3Address(saltQuipPortal, address(CREATEX));
    console.log('QuipPortal:', expectedPortal);

    // ERC20Mock
    bytes32 saltErc20 = _computeGuardedSalt(deployer, SALT_SUFFIX_ERC20_MOCK);
    address expectedErc20 = CREATEX.computeCreate3Address(saltErc20, address(CREATEX));
    console.log('ERC20Mock:', expectedErc20);

    // ERC721Mock
    bytes32 saltErc721 = _computeGuardedSalt(deployer, SALT_SUFFIX_ERC721_MOCK);
    address expectedErc721 = CREATEX.computeCreate3Address(saltErc721, address(CREATEX));
    console.log('ERC721Mock:', expectedErc721);

    // ERC1155Mock
    bytes32 saltErc1155 = _computeGuardedSalt(deployer, SALT_SUFFIX_ERC1155_MOCK);
    address expectedErc1155 = CREATEX.computeCreate3Address(saltErc1155, address(CREATEX));
    console.log('ERC1155Mock:', expectedErc1155);
  }

  // ============ Deployment Functions ============

  function _deployQuipContracts(address deployer, address admin) internal returns (address quipImpl, address portal) {
    console.log('');
    console.log('--- Deploying QUIP Contracts ---');

    // Deploy Quip implementation
    bytes32 saltQuipImpl = _computeGuardedSalt(deployer, SALT_SUFFIX_QUIP_IMPL);
    bytes memory quipInitCode = type(Quip).creationCode;
    quipImpl = CREATEX.deployCreate3(saltQuipImpl, quipInitCode);
    console.log('Quip implementation:', quipImpl);

    // Deploy QuipPortal
    bytes32 saltQuipPortal = _computeGuardedSalt(deployer, SALT_SUFFIX_QUIP_PORTAL);
    bytes memory portalInitCode =
      abi.encodePacked(type(QuipPortal).creationCode, abi.encode(admin, quipImpl, MAX_FEE, CREATION_FEE));
    portal = CREATEX.deployCreate3(saltQuipPortal, portalInitCode);
    console.log('QuipPortal:', portal);
  }

  function _deployMocks(address deployer) internal returns (address erc20, address erc721, address erc1155) {
    console.log('');
    console.log('--- Deploying Mock Tokens ---');

    // Deploy ERC20Mock
    bytes32 saltErc20 = _computeGuardedSalt(deployer, SALT_SUFFIX_ERC20_MOCK);
    bytes memory erc20InitCode =
      abi.encodePacked(type(ERC20Mock).creationCode, abi.encode('Mock Token', 'MOCK', uint8(18)));
    erc20 = CREATEX.deployCreate3(saltErc20, erc20InitCode);
    console.log('ERC20Mock:', erc20);

    // Deploy ERC721Mock
    bytes32 saltErc721 = _computeGuardedSalt(deployer, SALT_SUFFIX_ERC721_MOCK);
    bytes memory erc721InitCode = abi.encodePacked(type(ERC721Mock).creationCode, abi.encode('Mock NFT', 'MNFT'));
    erc721 = CREATEX.deployCreate3(saltErc721, erc721InitCode);
    console.log('ERC721Mock:', erc721);

    // Deploy ERC1155Mock
    bytes32 saltErc1155 = _computeGuardedSalt(deployer, SALT_SUFFIX_ERC1155_MOCK);
    bytes memory erc1155InitCode =
      abi.encodePacked(type(ERC1155Mock).creationCode, abi.encode('https://example.com/token/{id}.json'));
    erc1155 = CREATEX.deployCreate3(saltErc1155, erc1155InitCode);
    console.log('ERC1155Mock:', erc1155);
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
        (bool success,) = recipient.call{value: PUBLIC_TESTNET_NATIVE_FUND_AMOUNT}('');
        require(success, 'ETH transfer failed');
        console.log('  Funded (transfer):', PUBLIC_TESTNET_NATIVE_FUND_AMOUNT);
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
    console.log('       DETERMINISTIC DEPLOYMENT DONE   ');
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
    console.log('');
    console.log('NOTE: Addresses are deterministic across all EVM chains.');
    console.log('      Constructor arguments do NOT affect the address.');
  }
}
