// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../src/Quip.sol';
import {QuipPortal} from '../../src/QuipPortal.sol';
import {Asset, PartyTerms, QuipTerms} from '../../src/TermsLib.sol';
import {IQuipPortal} from '../../src/interfaces/IQuipPortal.sol';

import {ERC1155Mock} from '../mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../mocks/ERC721Mock.sol';
import {AssetHelper} from './AssetHelper.sol';
import {TermsHelper} from './TermsHelper.sol';

/// @title Test Base
/// @dev Base contract for all tests with shared setup, actors, and constants
abstract contract TestBase is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 public constant MAX_FEE = 1 ether;
  uint256 public constant CREATION_FEE = 0.01 ether;
  uint256 public constant DEFAULT_AMOUNT = 10 ether;
  uint64 public constant DEFAULT_EXPIRY_DELTA = 1 days;

  // Token IDs for testing - ALICE gets ERC721 IDs 1,2,3; BOB gets 4,5,6; CHARLIE gets 7,8,9
  uint256 public constant ERC721_TOKEN_ID = 1;
  uint256 public constant ERC1155_TOKEN_ID = 1;

  // ============ Actors ============

  address public ADMIN = makeAddr('admin');
  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public CHARLIE = makeAddr('charlie');
  address public ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  // ============ Contracts ============

  QuipPortal public portal;
  Quip public quipImpl;
  ERC20Mock public mockERC20;
  ERC721Mock public mockERC721;
  ERC1155Mock public mockERC1155;

  // ============ Test State ============

  bytes public constant DEFAULT_KEY = 'secret_key_12345';
  bytes32 public defaultLock;

  // ============ Setup ============

  function setUp() public virtual {
    // Deploy mock tokens
    mockERC20 = new ERC20Mock('MockToken', 'MTK', 18);
    mockERC721 = new ERC721Mock('MockNFT', 'MNFT');
    mockERC1155 = new ERC1155Mock('https://example.com/token/{id}.json');

    // Deploy Quip implementation
    quipImpl = new Quip();

    // Deploy QuipPortal
    portal = new QuipPortal(ADMIN, address(quipImpl), MAX_FEE, CREATION_FEE);

    // Compute default lock
    defaultLock = keccak256(DEFAULT_KEY);

    // Fund actors
    vm.deal(ALICE, 100 ether);
    vm.deal(BOB, 100 ether);
    vm.deal(CHARLIE, 100 ether);
    vm.deal(ADMIN, 100 ether);

    // Mint tokens to actors
    _mintTokensTo(ALICE);
    _mintTokensTo(BOB);
    _mintTokensTo(CHARLIE);
  }

  // ============ Internal Helpers ============

  function _mintTokensTo(address account) internal {
    mockERC20.mint(account, 1_000_000 ether);
    mockERC721.mint(account);
    mockERC721.mint(account);
    mockERC721.mint(account);
    mockERC1155.mint(account, 1, 1000, '');
    mockERC1155.mint(account, 2, 1000, '');
  }

  function _defaultExpiry() internal view returns (uint64) {
    return uint64(block.timestamp + DEFAULT_EXPIRY_DELTA);
  }

  function _expiredTimestamp() internal view returns (uint64) {
    return uint64(block.timestamp - 1);
  }

  function _approveAll(address owner) internal {
    vm.startPrank(owner);
    mockERC20.approve(address(portal), type(uint256).max);
    mockERC721.setApprovalForAll(address(portal), true);
    mockERC1155.setApprovalForAll(address(portal), true);
    vm.stopPrank();
  }

  function _approveAllForQuip(address owner, address quip) internal {
    vm.startPrank(owner);
    mockERC20.approve(quip, type(uint256).max);
    mockERC721.setApprovalForAll(quip, true);
    mockERC1155.setApprovalForAll(quip, true);
    vm.stopPrank();
  }

  function _makeNativeAssets(uint256 amount) internal pure returns (Asset[] memory) {
    return AssetHelper.makeNative(amount).toArray();
  }

  function _makeERC20Assets(uint256 amount) internal view returns (Asset[] memory) {
    return AssetHelper.makeERC20(address(mockERC20), amount).toArray();
  }

  function _makeERC721Assets(uint256 tokenId) internal view returns (Asset[] memory) {
    return AssetHelper.makeERC721(address(mockERC721), tokenId).toArray();
  }

  function _makeERC1155Assets(uint256 tokenId, uint256 amount) internal view returns (Asset[] memory) {
    return AssetHelper.makeERC1155(address(mockERC1155), tokenId, amount).toArray();
  }

  function _makeDefaultQuipTerms() internal view returns (QuipTerms memory) {
    return TermsHelper.makeSimpleQuipTerms(
      ALICE, BOB, _defaultExpiry(), _defaultExpiry(), _makeNativeAssets(1 ether), _makeNativeAssets(1 ether)
    );
  }

  function _makeDefaultPartyTerms() internal view returns (PartyTerms memory) {
    return TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, _defaultExpiry(), _makeNativeAssets(1 ether));
  }

  function _computeLock(bytes memory key) internal pure returns (bytes32) {
    return keccak256(key);
  }

  function _uniqueLock(uint256 salt) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked('lock', salt));
  }

  function _uniqueKey(uint256 salt) internal pure returns (bytes memory) {
    return abi.encodePacked('key', salt);
  }

  /// @dev Mirrors TermsLib.digestTerms but accepts memory instead of calldata.
  ///      TermsLib functions use calldata for gas efficiency in production,
  ///      but tests work with memory structs built dynamically.
  function _digestQuipTerms(QuipTerms memory terms) internal pure returns (bytes32) {
    return keccak256(
      abi.encode(
        terms.party,
        terms.partyRecipient,
        terms.counterparty,
        terms.counterpartyRecipient,
        terms.partyExpiry,
        terms.counterpartyExpiry,
        terms.partyAssets,
        terms.counterpartyAssets
      )
    );
  }

  /// @dev Mirrors TermsLib.digestPartyTerms but accepts memory instead of calldata.
  function _digestPartyTerms(PartyTerms memory terms) internal pure returns (bytes32) {
    return keccak256(abi.encode(terms.signatory, terms.recipient, terms.expiry, terms.assets));
  }

  /// @dev Mirrors TermsLib.coupleTerms but accepts memory instead of calldata.
  function _coupleTerms(
    PartyTerms memory party,
    PartyTerms memory counterparty
  ) internal pure returns (QuipTerms memory coupled) {
    coupled = QuipTerms({
      party: party.signatory,
      partyRecipient: party.recipient,
      counterparty: counterparty.signatory,
      counterpartyRecipient: counterparty.recipient,
      partyExpiry: party.expiry,
      counterpartyExpiry: counterparty.expiry,
      partyAssets: party.assets,
      counterpartyAssets: counterparty.assets
    });
  }

  /// @notice Finds the quip address from QuipCreated event in logs
  /// @notice Finds the quip address from QuipCreated event in logs
  /// @dev Event signature: QuipCreated(bytes32 indexed lock, address indexed quip, QuipTerms terms)
  function _findQuipCreatedAddress(Vm.Log[] memory logs) internal pure returns (address) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.QuipCreated.selector) {
        // topics[1] = lock (indexed), topics[2] = quip address (indexed)
        return address(uint160(uint256(logs[i].topics[2])));
      }
    }
    revert('QuipCreated event not found');
  }

  /// @notice Finds the quip address from QuipProposed event in logs
  /// @dev Event signature: QuipProposed(bytes32 indexed lock, address indexed quip, PartyTerms terms)
  function _findQuipProposedAddress(Vm.Log[] memory logs) internal pure returns (address) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.QuipProposed.selector) {
        // topics[1] = lock (indexed), topics[2] = quip address (indexed)
        return address(uint160(uint256(logs[i].topics[2])));
      }
    }
    revert('QuipProposed event not found');
  }
}
