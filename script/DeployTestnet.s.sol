// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Omnibus} from '../src/Omnibus.sol';
import {ERC1155Mock} from '../test/mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../test/mocks/ERC20Mock.sol';
import {ERC721Mock} from '../test/mocks/ERC721Mock.sol';
import {Script, console} from 'forge-std-1.14.0/Script.sol';
import {ICreateX} from 'pcaversaccio-createx-1.0.0/src/ICreateX.sol';

/// @title DeployTestnet
/// @notice Testnet deployment script for Omnibus + mock tokens
contract DeployTestnet is Script {
  /// @notice CreateX factory address (same on all chains)
  ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

  /// @notice Salt suffixes for deterministic deployment
  bytes11 public constant SALT_SUFFIX_OMNIBUS = bytes11(keccak256('quip.network.Omnibus.v1'));
  bytes11 public constant SALT_SUFFIX_ERC20_MOCK = bytes11(keccak256('quip.network.ERC20Mock.v1'));
  bytes11 public constant SALT_SUFFIX_ERC721_MOCK = bytes11(keccak256('quip.network.ERC721Mock.v1'));
  bytes11 public constant SALT_SUFFIX_ERC1155_MOCK = bytes11(keccak256('quip.network.ERC1155Mock.v1'));

  /// @notice Owner address for the Omnibus contract
  address public constant OMNIBUS_OWNER = 0xc68B64770Da7914DEb0EF238b048a0Bf3B5f6A26;

  /// @notice Minting amounts
  uint256 public constant ERC20_MINT_AMOUNT = 1_000_000 ether;
  uint256 public constant ERC721_MINT_COUNT = 3;
  uint256 public constant ERC1155_MINT_AMOUNT = 1000;
  uint256 public constant NATIVE_FUND_AMOUNT = 100 ether;

  /// @notice Computes a guarded salt for CreateX deployment
  /// @dev Guarded salt format: deployer (20 bytes) + 0x00 (1 byte) + suffix (11 bytes)
  /// @param deployer The deployer address that will be guarded
  /// @param suffix The 11-byte salt suffix
  /// @return The 32-byte guarded salt
  function _computeGuardedSalt(address deployer, bytes11 suffix) internal pure returns (bytes32) {
    return bytes32(abi.encodePacked(deployer, bytes1(0x00), suffix));
  }

  /// @notice Returns test addresses to fund with tokens
  function _getTestAddresses() internal pure returns (address[] memory) {
    address[] memory addresses = new address[](1);
    addresses[0] = 0xc68B64770Da7914DEb0EF238b048a0Bf3B5f6A26;
    return addresses;
  }

  function run() external {
    uint256 deployerPk = vm.envUint('DEPLOYER_PK');
    address deployer = vm.addr(deployerPk);

    console.log('Deployer:', deployer);
    console.log('Chain ID:', block.chainid);

    // Compute expected addresses
    bytes32 saltOmnibus = _computeGuardedSalt(deployer, SALT_SUFFIX_OMNIBUS);
    bytes32 saltERC20 = _computeGuardedSalt(deployer, SALT_SUFFIX_ERC20_MOCK);
    bytes32 saltERC721 = _computeGuardedSalt(deployer, SALT_SUFFIX_ERC721_MOCK);
    bytes32 saltERC1155 = _computeGuardedSalt(deployer, SALT_SUFFIX_ERC1155_MOCK);

    address expectedOmnibus = CREATEX.computeCreate3Address(saltOmnibus, address(CREATEX));
    address expectedERC20 = CREATEX.computeCreate3Address(saltERC20, address(CREATEX));
    address expectedERC721 = CREATEX.computeCreate3Address(saltERC721, address(CREATEX));
    address expectedERC1155 = CREATEX.computeCreate3Address(saltERC1155, address(CREATEX));

    console.log('Expected Omnibus:', expectedOmnibus);
    console.log('Expected ERC20Mock:', expectedERC20);
    console.log('Expected ERC721Mock:', expectedERC721);
    console.log('Expected ERC1155Mock:', expectedERC1155);

    vm.startBroadcast(deployerPk);

    // Deploy Omnibus
    address omnibus;
    if (expectedOmnibus.code.length == 0) {
      bytes memory omnibusInitCode = abi.encodePacked(type(Omnibus).creationCode, abi.encode(OMNIBUS_OWNER));
      omnibus = CREATEX.deployCreate3(saltOmnibus, omnibusInitCode);
      console.log('Omnibus deployed at:', omnibus);
    } else {
      omnibus = expectedOmnibus;
      console.log('Omnibus already deployed at:', omnibus);
    }

    // Deploy ERC20Mock
    ERC20Mock erc20;
    if (expectedERC20.code.length == 0) {
      bytes memory erc20InitCode =
        abi.encodePacked(type(ERC20Mock).creationCode, abi.encode('Mock Token', 'MOCK', uint8(18)));
      erc20 = ERC20Mock(CREATEX.deployCreate3(saltERC20, erc20InitCode));
      console.log('ERC20Mock deployed at:', address(erc20));
    } else {
      erc20 = ERC20Mock(expectedERC20);
      console.log('ERC20Mock already deployed at:', address(erc20));
    }

    // Deploy ERC721Mock
    ERC721Mock erc721;
    if (expectedERC721.code.length == 0) {
      bytes memory erc721InitCode = abi.encodePacked(type(ERC721Mock).creationCode, abi.encode('Mock NFT', 'MNFT'));
      erc721 = ERC721Mock(CREATEX.deployCreate3(saltERC721, erc721InitCode));
      console.log('ERC721Mock deployed at:', address(erc721));
    } else {
      erc721 = ERC721Mock(expectedERC721);
      console.log('ERC721Mock already deployed at:', address(erc721));
    }

    // Deploy ERC1155Mock
    ERC1155Mock erc1155;
    if (expectedERC1155.code.length == 0) {
      bytes memory erc1155InitCode =
        abi.encodePacked(type(ERC1155Mock).creationCode, abi.encode('https://example.com/token/{id}.json'));
      erc1155 = ERC1155Mock(CREATEX.deployCreate3(saltERC1155, erc1155InitCode));
      console.log('ERC1155Mock deployed at:', address(erc1155));
    } else {
      erc1155 = ERC1155Mock(expectedERC1155);
      console.log('ERC1155Mock already deployed at:', address(erc1155));
    }

    // Fund test addresses
    address[] memory testAddresses = _getTestAddresses();
    for (uint256 i = 0; i < testAddresses.length; i++) {
      address testAddr = testAddresses[i];
      console.log('Funding test address:', testAddr);

      // Mint ERC20
      erc20.mint(testAddr, ERC20_MINT_AMOUNT);

      // Mint ERC721s
      for (uint256 j = 0; j < ERC721_MINT_COUNT; j++) {
        erc721.mint(testAddr);
      }

      // Mint ERC1155 (token IDs 1, 2, 3)
      erc1155.mint(testAddr, 1, ERC1155_MINT_AMOUNT, '');
      erc1155.mint(testAddr, 2, ERC1155_MINT_AMOUNT, '');
      erc1155.mint(testAddr, 3, ERC1155_MINT_AMOUNT, '');

      // Fund with native ETH (transfer from deployer)
      if (testAddr.balance < NATIVE_FUND_AMOUNT) {
        (bool success,) = testAddr.call{value: NATIVE_FUND_AMOUNT}('');
        require(success, 'Native transfer failed');
      }
    }

    vm.stopBroadcast();

    console.log('Testnet deployment complete');
  }
}
