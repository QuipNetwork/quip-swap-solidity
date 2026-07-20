// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Asset, Terms} from '../../src/TermsLib.sol';
import {TermsLibHarness} from '../harness/TermsLibHarness.sol';
import {ERC1155Mock} from '../mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';

/// @title TermsLib Base Test
/// @dev Base contract for testing TermsLib
contract TermsLibTest is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Contracts ============

  TermsLibHarness public harness;
  ERC20Mock public mockERC20;
  ERC721Mock public mockERC721;
  ERC1155Mock public mockERC1155;

  // ============ Actors ============

  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  // ============ Constants ============

  uint256 public constant DEFAULT_COMMITMENT_DEADLINE = 1_000_000;
  uint256 public constant DEFAULT_CLAIM_DEADLINE = 2_000_000;
  uint256 public constant DEFAULT_RECLAIM_RELEASE = 3_000_000;
  uint256 public constant DEFAULT_AMOUNT = 10 ether;

  /// @notice a Solana-style 32-byte pubkey: high bit forced so it can never
  /// narrow to an EVM address
  bytes32 public constant SOLANA_PUBKEY = bytes32(uint256(keccak256('SOLANA_PUBKEY_FIXTURE')) | (uint256(1) << 255));

  /// @notice a second distinct Solana-style pubkey for mint/recipient pairs
  bytes32 public constant SOLANA_MINT = bytes32(uint256(keccak256('SOLANA_MINT_FIXTURE')) | (uint256(1) << 255));

  /// @notice a foreign chainId standing in for Solana in cross-chain fixtures
  uint256 public constant SOLANA_CHAIN_ID = uint256(keccak256('solana:mainnet'));

  // ============ Pinned digest vectors (Solidity ↔ SDK parity) ============
  // A vector = a frozen Terms fixture (bottom of this file) + the digest it must
  // hash to. The digest is PINNED, not derived: deriving it at test time from the
  // fixture would only prove the implementation agrees with itself, while the pin
  // is the absolute anchor every implementation (Solidity here, TS in
  // sdk/test/unit/hashing.test.ts, Rust later) must independently reproduce.
  // Never change a fixture or pin on one side without the other — a mismatch is
  // digest drift, not a test to "fix"

  /// @notice pinned digestTerms(_evmVectorTerms()); equals the pre-bytes32-widening
  /// digest for the same terms (low-20-byte alignment matches abi.encode(address))
  bytes32 public constant EVM_VECTOR_DIGEST = 0xba4a8385b187ea45d0feb380b65b7532b94f11d9bb2008d4b78fa12e39fc0b79;

  /// @notice pinned digestTerms(_solanaVectorTerms()) — exercises the high-bit
  /// bytes32 range unreachable before the widening
  bytes32 public constant SOLANA_VECTOR_DIGEST = 0x8af3881416101f8354049a0f961f624ccc5b1759141357463856f5c0e0ee9528;

  /// @notice pinned digestTermsCanonically(evm, solana) — the two vectors form a
  /// valid interleaved pairing, hashed order-independently
  bytes32 public constant CANONICAL_PAIR_DIGEST = 0xbf1f3cf7a5b7fda84a14091f47f7b963c57a04d1bab8578927cfa6c10e09fbb7;

  // ============ Setup ============

  function setUp() public virtual {
    harness = new TermsLibHarness();

    mockERC20 = new ERC20Mock('MockToken', 'MTK', 18);
    mockERC721 = new ERC721Mock('MockNFT', 'MNFT');
    mockERC1155 = new ERC1155Mock('https://example.com/token/{id}.json');

    // fund accounts
    vm.deal(ALICE, 100 ether);
    vm.deal(BOB, 100 ether);
    vm.deal(address(harness), 100 ether);

    // mint tokens
    mockERC20.mint(ALICE, 1_000_000 ether);
    mockERC20.mint(BOB, 1_000_000 ether);
    mockERC20.mint(address(harness), 1_000_000 ether);

    mockERC721.mint(ALICE, 1);
    mockERC721.mint(ALICE, 2);
    mockERC721.mint(BOB, 3);
    mockERC721.mint(BOB, 4);
    mockERC721.mint(address(harness), 5);

    mockERC1155.mint(ALICE, 1, 1000, '');
    mockERC1155.mint(BOB, 2, 1000, '');
    mockERC1155.mint(address(harness), 1, 1000, '');
  }

  function test_setUp() public view {
    assertNotEq(address(harness), address(0));
    assertNotEq(address(mockERC20), address(0));
    assertNotEq(address(mockERC721), address(0));
    assertNotEq(address(mockERC1155), address(0));
  }

  // ============ Internal Helpers ============

  /// @notice widens an EVM address to its bytes32 identifier (low 20 bytes)
  function _b32(address addr) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(addr)));
  }

  function _makeNativeAsset(uint256 amount) internal pure returns (Asset memory) {
    return AssetHelper.makeNative(amount);
  }

  function _makeERC20Asset(uint256 amount) internal view returns (Asset memory) {
    return AssetHelper.makeERC20(address(mockERC20), amount);
  }

  function _makeERC721Asset(uint256 tokenId) internal view returns (Asset memory) {
    return AssetHelper.makeERC721(address(mockERC721), tokenId);
  }

  function _makeERC1155Asset(uint256 tokenId, uint256 amount) internal view returns (Asset memory) {
    return AssetHelper.makeERC1155(address(mockERC1155), tokenId, amount);
  }

  function _defaultTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );
  }

  // ============ Digest vector fixtures (pins at top of file) ============

  /// @dev all-EVM vector: proposer-scheduled leg with fixed literal addresses;
  /// must hash to EVM_VECTOR_DIGEST
  function _evmVectorTerms() internal pure returns (Terms memory) {
    return TermsHelper.makeTerms(
      31_337, address(0xA11CE), address(0xB0B), 1000, 2000, 3000, AssetHelper.makeNative(1 ether).toArray()
    );
  }

  /// @dev Solana-styled vector: taker-scheduled leg on the Solana chainId with a
  /// foreign mint target + foreign reclaimRecipient and an EVM recipient (the
  /// recipient receives on the counterparty's chain); u64-safe amount; must hash
  /// to SOLANA_VECTOR_DIGEST
  function _solanaVectorTerms() internal pure returns (Terms memory) {
    return TermsHelper.makeTerms(
      SOLANA_CHAIN_ID,
      SOLANA_PUBKEY,
      bytes32(uint256(0xAA)),
      1500,
      2500,
      3500,
      AssetHelper.makeERC20(SOLANA_MINT, 1_000_000_000).toArray()
    );
  }
}
