// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType, Terms} from '../../src/TermsLib.sol';
import {LockState} from '../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../harness/OmnibusHarness.sol';
import {QuipFactoryMock} from '../mocks/QuipFactoryMock.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';
import {TestBase} from '../utils/TestBase.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

/// @title Omnibus Base Test
/// @dev Base contract for testing Omnibus.
///
/// Timing model. The protocol partitions the swap timeline into half-open windows and the
/// contract enforces, per action, that block.timestamp falls in the right one (see
/// TermsLib.enforceWithin). Terms are strictly interleaved (TermsLib.validateTermPairing):
/// Alice is the PROPOSER (commits first), Bob is the TAKER. The six deadlines satisfy
///   ALICE_COMMIT < BOB_COMMIT < ALICE_CLAIM < BOB_CLAIM < ALICE_RECLAIM < BOB_RECLAIM
/// and each action has a representative time anchor strictly inside its window. _commitFor
/// auto-warps into the committing party's commit window based on its role, so commit call
/// sites need no manual warping.
contract OmnibusTest is TestBase {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants (Omnibus-specific) ============

  uint256 public constant OTHER_CHAIN_ID = 999;
  uint256 public constant ERC721_ALICE_TOKEN = 1;
  uint256 public constant ERC721_BOB_TOKEN = 2;
  uint256 public constant ERC1155_TOKEN_ID = 1;

  // ============ Lifecycle Deadlines (Alice = proposer, Bob = taker) ============

  uint256 public constant ALICE_COMMIT_DEADLINE = 1000;
  uint256 public constant BOB_COMMIT_DEADLINE = 2000;
  uint256 public constant ALICE_CLAIM_DEADLINE = 3000;
  uint256 public constant BOB_CLAIM_DEADLINE = 4000;
  uint256 public constant ALICE_RECLAIM_RELEASE = 5000;
  uint256 public constant BOB_RECLAIM_RELEASE = 6000;

  // ============ Action Time Anchors (each strictly inside its window) ============

  uint256 public constant AT_PROPOSER_COMMIT = 500; //   [0, ALICE_COMMIT)
  uint256 public constant AT_TAKER_COMMIT = 1500; //    [ALICE_COMMIT, BOB_COMMIT)
  uint256 public constant AT_PROPOSER_CLAIM = 2500; //  [BOB_COMMIT, ALICE_CLAIM)
  uint256 public constant AT_TAKER_CLAIM = 3500; //     [ALICE_CLAIM, ALICE_RECLAIM)
  uint256 public constant AT_PROPOSER_RECLAIM = 5500; // [ALICE_RECLAIM, inf)
  uint256 public constant AT_TAKER_RECLAIM = 6500; //   [BOB_RECLAIM, inf)

  // ============ Contracts ============

  OmnibusHarness public omnibus;
  QuipFactoryMock public quipFactory;

  // ============ Test Data ============

  bytes32 public constant SECRET = keccak256('secret');
  bytes32 public lock;

  // ============ Setup ============

  function setUp() public virtual override {
    super.setUp();

    // Deploy QuipFactory mock and register actors as quip wallets (commit is
    // gated to factory-deployed wallets)
    quipFactory = new QuipFactoryMock();
    _registerQuipWallet(ALICE);
    _registerQuipWallet(BOB);
    _registerQuipWallet(CHARLIE);

    // Deploy Omnibus harness
    omnibus = new OmnibusHarness(address(this), address(quipFactory));

    // Generate lock from secret
    lock = omnibus.exposed_generateLock(SECRET);

    // Fund omnibus
    vm.deal(address(omnibus), 100 ether);

    // Mint tokens to omnibus
    _mintTokensTo(address(omnibus));

    // Approve omnibus for actors
    _approveAllForOmnibus(ALICE);
    _approveAllForOmnibus(BOB);
    _approveAllForOmnibus(CHARLIE);
  }

  function test_setUp() public view {
    assertNotEq(address(omnibus), address(0));
    assertNotEq(address(mockERC20), address(0));
    assertNotEq(address(mockERC721), address(0));
    assertNotEq(address(mockERC1155), address(0));
    assertEq(omnibus.VERSION(), 0);
    assertEq(address(omnibus.QUIP_FACTORY()), address(quipFactory));
    assertNotEq(quipFactory.vaultIdOf(ALICE), bytes32(0));
    assertNotEq(quipFactory.vaultIdOf(BOB), bytes32(0));
    assertNotEq(quipFactory.vaultIdOf(CHARLIE), bytes32(0));
  }

  // ============ Internal Helpers ============

  /// @notice Approve omnibus harness to spend owner's tokens
  function _approveAllForOmnibus(address owner) internal {
    _approveAllFor(owner, address(omnibus));
  }

  /// @notice Register `wallet` in the factory mock so it passes the onlyQuipWallet gate
  function _registerQuipWallet(address wallet) internal {
    quipFactory.registerWallet(wallet, bytes32(uint256(uint160(wallet))), wallet);
  }

  // ============ Asset Helpers (single asset variants) ============

  function _makeERC20Asset(uint256 amount) internal view returns (Asset memory) {
    return AssetHelper.makeERC20(address(mockERC20), amount);
  }

  function _makeERC721Asset(uint256 tokenId) internal view returns (Asset memory) {
    return AssetHelper.makeERC721(address(mockERC721), tokenId);
  }

  function _makeERC1155Asset(uint256 tokenId, uint256 amount) internal view returns (Asset memory) {
    return AssetHelper.makeERC1155(address(mockERC1155), tokenId, amount);
  }

  // ============ Terms Helpers ============

  /// @notice Creates terms with explicit lifecycle deadlines
  function _makeTerms(
    uint256 chainId,
    address reclaimRecipient,
    address recipient,
    uint256 commitmentDeadline,
    uint256 claimDeadline,
    uint256 reclaimRelease,
    Asset[] memory assets
  ) internal pure returns (Terms memory) {
    return TermsHelper.makeTerms(
      chainId, reclaimRecipient, recipient, commitmentDeadline, claimDeadline, reclaimRelease, assets
    );
  }

  /// @notice Proposer (Alice) terms on a given chain with the proposer deadline schedule
  function _aliceTermsOn(uint256 chainId, Asset[] memory assets) internal view returns (Terms memory) {
    return _makeTerms(
      chainId, ALICE, ALICE_RECIPIENT, ALICE_COMMIT_DEADLINE, ALICE_CLAIM_DEADLINE, ALICE_RECLAIM_RELEASE, assets
    );
  }

  /// @notice Taker (Bob) terms on a given chain with the taker deadline schedule
  function _bobTermsOn(uint256 chainId, Asset[] memory assets) internal view returns (Terms memory) {
    return _makeTerms(chainId, BOB, BOB_RECIPIENT, BOB_COMMIT_DEADLINE, BOB_CLAIM_DEADLINE, BOB_RECLAIM_RELEASE, assets);
  }

  /// @notice Default same-chain proposer terms for Alice (native)
  function _aliceTerms() internal view returns (Terms memory) {
    return _aliceTermsOn(block.chainid, _makeNativeAssets(DEFAULT_AMOUNT));
  }

  /// @notice Default same-chain taker terms for Bob (ERC20)
  function _bobTerms() internal view returns (Terms memory) {
    return _bobTermsOn(block.chainid, _makeERC20Assets(DEFAULT_AMOUNT));
  }

  /// @notice Cross-chain taker terms for Bob (on OTHER_CHAIN_ID)
  function _bobCrossChainTerms() internal view returns (Terms memory) {
    return _bobTermsOn(OTHER_CHAIN_ID, _makeERC20Assets(DEFAULT_AMOUNT));
  }

  /// @notice Calculate native amount required for commit (excludes fee)
  function _totalNativeForCommit(Terms memory terms) internal pure returns (uint256 total) {
    for (uint256 i = 0; i < terms.assets.length; i++) {
      if (terms.assets[i].assetType == AssetType.Native) {
        total += terms.assets[i].amount;
      }
    }
  }

  // ============ Timing Helpers ============

  /// @notice true if `party` is the proposer of the pairing (commits first)
  function _isProposer(Terms memory party, Terms memory counterparty) internal pure returns (bool) {
    return party.commitmentDeadline < counterparty.commitmentDeadline;
  }

  function _warpToProposerClaim() internal {
    vm.warp(AT_PROPOSER_CLAIM);
  }

  function _warpToTakerClaim() internal {
    vm.warp(AT_TAKER_CLAIM);
  }

  function _warpToProposerReclaim() internal {
    vm.warp(AT_PROPOSER_RECLAIM);
  }

  function _warpToTakerReclaim() internal {
    vm.warp(AT_TAKER_RECLAIM);
  }

  // ============ Commit Helpers ============

  /// @notice Commit `party` against `counterparty`, auto-warping into the party's commit
  ///         window (proposer commits before its deadline; taker commits after the proposer's
  ///         deadline) and forwarding the required native value plus the current fee
  function _commitFor(address committer, bytes32 _lock, Terms memory party, Terms memory counterparty) internal {
    vm.warp(_isProposer(party, counterparty) ? AT_PROPOSER_COMMIT : AT_TAKER_COMMIT);
    uint256 value = _totalNativeForCommit(party) + omnibus.commitmentFee();
    vm.prank(committer);
    omnibus.commit{value: value}(_lock, party, counterparty);
  }

  /// @notice Helper to commit both parties for same-chain swaps (proposer then taker)
  function _commitBothParties(bytes32 _lock, Terms memory alice, Terms memory bob) internal {
    _commitFor(ALICE, _lock, alice, bob);
    _commitFor(BOB, _lock, bob, alice);
  }

  /// @notice Commit both, then settle same-chain by having the proposer (secret holder)
  ///         claim in the proposer-claim window (one claim settles both legs same-chain)
  function _settleSameChain(bytes32 _lock, Terms memory alice, Terms memory bob) internal {
    _commitBothParties(_lock, alice, bob);
    _warpToProposerClaim();
    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);
  }

  // ============ Assertion Helpers ============

  /// @notice Assert lock state
  function _assertLockState(bytes32 _lock, LockState expected) internal view {
    assertEq(uint8(omnibus.lockState(_lock)), uint8(expected));
  }

  /// @notice Assert event was emitted with specific topic
  function _assertEventEmitted(Vm.Log[] memory logs, bytes32 eventSelector, bytes32 expectedTopic1) internal pure {
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == eventSelector) {
        assertEq(logs[i].topics[1], expectedTopic1);
        return;
      }
    }
    revert('Event not found');
  }
}
