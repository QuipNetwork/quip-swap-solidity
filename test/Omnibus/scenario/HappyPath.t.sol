// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Asset, Terms, TermsLib} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../../harness/OmnibusHarness.sol';
import {ERC1155Mock} from '../../mocks/ERC1155Mock.sol';
import {ERC20Mock} from '../../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../../mocks/ERC721Mock.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';

/// @title Omnibus Happy Path Scenarios
/// @dev Tests for successful swap flows
contract Omnibus_HappyPath is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 constant CHAIN_A = 1;
  uint256 constant CHAIN_B = 137;

  // ============ Actors ============

  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public CHARLIE = makeAddr('charlie');
  address public ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  // ============ Contracts ============

  OmnibusHarness public omnibus;
  OmnibusHarness public omnibusA;
  OmnibusHarness public omnibusB;
  ERC20Mock public mockERC20;
  ERC20Mock public tokenA;
  ERC20Mock public tokenB;
  ERC721Mock public mockERC721;
  ERC1155Mock public mockERC1155;

  // ============ Test Data ============

  bytes32 public constant SECRET = keccak256('secret');
  bytes32 public lock;

  // ============ Setup ============

  function setUp() public virtual {
    // Deploy mock tokens
    mockERC20 = new ERC20Mock('MockToken', 'MTK', 18);
    mockERC721 = new ERC721Mock('MockNFT', 'MNFT');
    mockERC1155 = new ERC1155Mock('https://example.com/token/{id}.json');

    // Deploy Omnibus instances
    omnibus = new OmnibusHarness();
    omnibusA = new OmnibusHarness();
    omnibusB = new OmnibusHarness();

    // Deploy chain-specific tokens
    tokenA = new ERC20Mock('TokenA', 'TKA', 18);
    tokenB = new ERC20Mock('TokenB', 'TKB', 18);

    // Generate lock from secret
    lock = TermsLib.generateLock(SECRET);

    // Fund actors
    vm.deal(ALICE, 100 ether);
    vm.deal(BOB, 100 ether);
    vm.deal(CHARLIE, 100 ether);

    // Mint tokens to actors
    _mintTokensTo(ALICE);
    _mintTokensTo(BOB);

    // Approve omnibus for all actors
    _approveAllForOmnibus(ALICE, omnibus);
    _approveAllForOmnibus(BOB, omnibus);
  }

  // ============ Scenario 1: Same-Chain Native Swap ============

  /// @notice Test successful same-chain native swap between Alice and Bob
  function test_scenario_sameChain_nativeSwap_success() public {
    // Setup: Alice offers 1 ETH + 0.1 ETH collateral
    // Bob offers 0.5 ETH + 0.1 ETH collateral
    uint256 aliceAssetAmount = 1 ether;
    uint256 bobAssetAmount = 0.5 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(aliceAssetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(bobAssetAmount).toArray()
    );

    // Step 1: Alice commits first (same-chain -> Free state)
    uint256 aliceNativeRequired = aliceAssetAmount + collateralAmount; // 1.1 ETH
    vm.prank(ALICE);
    omnibus.commit{value: aliceNativeRequired}(lock, aliceTerms, bobTerms);

    // Verify: lock state = Free (waiting for counterparty on same chain)
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    // Step 2: Bob commits second (same-chain -> Committed state)
    uint256 bobNativeRequired = bobAssetAmount + collateralAmount; // 0.6 ETH
    vm.prank(BOB);
    omnibus.commit{value: bobNativeRequired}(lock, bobTerms, aliceTerms);

    // Verify: lock state = Committed
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));

    // Record balances before execution
    uint256 bobRecipientBalBefore = BOB_RECIPIENT.balance;
    uint256 aliceRecipientBalBefore = ALICE_RECIPIENT.balance;
    uint256 aliceBalBefore = ALICE.balance;
    uint256 bobBalBefore = BOB.balance;
    uint256 omnibusBalBefore = address(omnibus).balance;

    // Step 3: Charlie executes with secret
    vm.prank(CHARLIE);
    omnibus.execute(SECRET, aliceTerms, bobTerms);

    // Verify: lock state = Spent
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // Verify: BOB_RECIPIENT received Alice's assets (1 ETH)
    assertEq(BOB_RECIPIENT.balance - bobRecipientBalBefore, aliceAssetAmount);

    // Verify: ALICE_RECIPIENT received Bob's assets (0.5 ETH)
    assertEq(ALICE_RECIPIENT.balance - aliceRecipientBalBefore, bobAssetAmount);

    // Verify: ALICE received her collateral back (0.1 ETH)
    assertEq(ALICE.balance - aliceBalBefore, collateralAmount);

    // Verify: BOB received his collateral back (0.1 ETH)
    assertEq(BOB.balance - bobBalBefore, collateralAmount);

    // Verify: Omnibus balance = 0
    assertEq(address(omnibus).balance, omnibusBalBefore - aliceNativeRequired - bobNativeRequired);
  }

  // ============ Scenario 2: Same-Chain Mixed Assets Swap ============

  /// @notice Test successful same-chain swap with mixed asset types
  function test_scenario_sameChain_mixedAssets_success() public {
    // Mint specific tokens
    mockERC721.mint(ALICE); // NFT id 1

    // Build terms using helper
    (Terms memory aliceTerms, Terms memory bobTerms) = _buildMixedAssetTerms();

    // Alice commits with 1 ETH msg.value
    vm.prank(ALICE);
    omnibus.commit{value: 1 ether}(lock, aliceTerms, bobTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    // Bob commits with 0 msg.value (no native)
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bobTerms, aliceTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));

    // Record balances
    uint256 bobRecipientEthBefore = BOB_RECIPIENT.balance;
    uint256 bobRecipientERC20Before = mockERC20.balanceOf(BOB_RECIPIENT);

    // Execute
    omnibus.execute(SECRET, aliceTerms, bobTerms);

    // Verify: BOB_RECIPIENT received 1 ETH + 100 ERC20
    assertEq(BOB_RECIPIENT.balance - bobRecipientEthBefore, 1 ether);
    assertEq(mockERC20.balanceOf(BOB_RECIPIENT) - bobRecipientERC20Before, 100 ether);

    // Verify: ALICE_RECIPIENT received 10 ERC1155
    assertEq(mockERC1155.balanceOf(ALICE_RECIPIENT, 1), 10);

    // Verify: ALICE got her NFT collateral back
    assertEq(mockERC721.ownerOf(1), ALICE);

    // Verify: BOB got his ERC20 collateral back
    assertGe(mockERC20.balanceOf(BOB), 50 ether);
  }

  /// @dev Helper to build mixed asset terms (reduces stack depth)
  function _buildMixedAssetTerms() internal view returns (Terms memory aliceTerms, Terms memory bobTerms) {
    uint64 deadline = uint64(block.timestamp + 1 days);

    // Alice terms: 1 ETH native + 100 ERC20, collateral = NFT
    Asset[] memory aliceAssets = new Asset[](2);
    aliceAssets[0] = AssetHelper.makeNative(1 ether);
    aliceAssets[1] = AssetHelper.makeERC20(address(mockERC20), 100 ether);

    aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeERC721(address(mockERC721), 1),
      aliceAssets
    );

    // Bob terms: 10 ERC1155, collateral = 50 ERC20
    Asset[] memory bobAssets = new Asset[](1);
    bobAssets[0] = AssetHelper.makeERC1155(address(mockERC1155), 1, 10);

    bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeERC20(address(mockERC20), 50 ether),
      bobAssets
    );
  }

  // ============ Scenario 3: Cross-Chain Complete Swap ============

  /// @notice Test successful cross-chain swap (Alice on Chain A, Bob on Chain B)
  function test_scenario_crossChain_completeSwap_success() public {
    bytes32 secret = keccak256('crosschain-secret');
    bytes32 crossLock = TermsLib.generateLock(secret);
    uint64 deadline = uint64(block.timestamp + 1 days);
    uint256 tokenAAmount = 100 ether;
    uint256 tokenBAmount = 200 ether;
    uint256 collateralAmount = 0.1 ether;

    // === PHASE 1: Setup ===
    // Mint tokens
    tokenA.mint(ALICE, tokenAAmount);
    tokenB.mint(BOB, tokenBAmount);

    // === PHASE 2: Create Terms (ONCE, reused on both chains) ===
    Terms memory aliceTerms = TermsHelper.makeTerms(
      CHAIN_A,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeERC20(address(tokenA), tokenAAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      CHAIN_B,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeERC20(address(tokenB), tokenBAmount).toArray()
    );

    // === PHASE 3: Alice commits on Chain A ===
    vm.chainId(CHAIN_A);
    vm.startPrank(ALICE);
    tokenA.approve(address(omnibusA), tokenAAmount);
    vm.stopPrank();

    vm.prank(ALICE);
    omnibusA.commit{value: collateralAmount}(crossLock, aliceTerms, bobTerms);

    // Cross-chain: goes directly to Committed (not Free)
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Committed));
    assertEq(tokenA.balanceOf(address(omnibusA)), tokenAAmount);

    // Verify Chain B state is INDEPENDENT
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Unused));

    // === PHASE 4: Bob commits on Chain B ===
    vm.chainId(CHAIN_B);
    vm.startPrank(BOB);
    tokenB.approve(address(omnibusB), tokenBAmount);
    vm.stopPrank();

    vm.prank(BOB);
    omnibusB.commit{value: collateralAmount}(crossLock, bobTerms, aliceTerms);

    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Committed));
    assertEq(tokenB.balanceOf(address(omnibusB)), tokenBAmount);

    // Verify Chain A state is unchanged
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Committed));

    // === PHASE 5: Execute on Chain A ===
    vm.chainId(CHAIN_A);
    uint256 aliceBalBefore = ALICE.balance;
    uint256 bobRecipientTokenBefore = tokenA.balanceOf(BOB_RECIPIENT);

    omnibusA.execute(secret, aliceTerms, bobTerms);

    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Spent));
    assertEq(tokenA.balanceOf(BOB_RECIPIENT) - bobRecipientTokenBefore, tokenAAmount);
    assertEq(ALICE.balance - aliceBalBefore, collateralAmount);

    // Verify Chain B state is STILL Committed (not affected by Chain A execution)
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Committed));

    // === PHASE 6: Execute on Chain B ===
    vm.chainId(CHAIN_B);
    uint256 bobBalBefore = BOB.balance;
    uint256 aliceRecipientTokenBefore = tokenB.balanceOf(ALICE_RECIPIENT);

    omnibusB.execute(secret, bobTerms, aliceTerms);

    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Spent));
    assertEq(tokenB.balanceOf(ALICE_RECIPIENT) - aliceRecipientTokenBefore, tokenBAmount);
    assertEq(BOB.balance - bobBalBefore, collateralAmount);

    // === FINAL VERIFICATION ===
    assertEq(tokenA.balanceOf(address(omnibusA)), 0);
    assertEq(tokenB.balanceOf(address(omnibusB)), 0);
  }

  // ============ Scenario 4: Cross-Chain Reclaim ============

  /// @notice Test cross-chain reclaim where both parties cancel
  function test_scenario_crossChain_reclaimBothChains_success() public {
    bytes32 secret = keccak256('reclaim-secret');
    bytes32 reclaimLock = TermsLib.generateLock(secret);
    uint64 deadline = uint64(block.timestamp + 1 days);
    uint256 tokenAAmount = 100 ether;
    uint256 tokenBAmount = 200 ether;
    uint256 collateralAmount = 0.1 ether;

    // Mint tokens
    tokenA.mint(ALICE, tokenAAmount);
    tokenB.mint(BOB, tokenBAmount);

    // Create terms (reused on both chains)
    Terms memory aliceTerms = TermsHelper.makeTerms(
      CHAIN_A,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeERC20(address(tokenA), tokenAAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      CHAIN_B,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeERC20(address(tokenB), tokenBAmount).toArray()
    );

    // === COMMITS ===
    vm.chainId(CHAIN_A);
    vm.startPrank(ALICE);
    tokenA.approve(address(omnibusA), tokenAAmount);
    omnibusA.commit{value: collateralAmount}(reclaimLock, aliceTerms, bobTerms);
    vm.stopPrank();
    assertEq(uint8(omnibusA.lockState(reclaimLock)), uint8(LockState.Committed));
    assertEq(uint8(omnibusB.lockState(reclaimLock)), uint8(LockState.Unused));

    vm.chainId(CHAIN_B);
    vm.startPrank(BOB);
    tokenB.approve(address(omnibusB), tokenBAmount);
    omnibusB.commit{value: collateralAmount}(reclaimLock, bobTerms, aliceTerms);
    vm.stopPrank();
    assertEq(uint8(omnibusB.lockState(reclaimLock)), uint8(LockState.Committed));
    assertEq(uint8(omnibusA.lockState(reclaimLock)), uint8(LockState.Committed));

    // === RECLAIM ON CHAIN A ===
    vm.chainId(CHAIN_A);
    uint256 aliceTokenBefore = tokenA.balanceOf(ALICE);
    uint256 aliceEthBefore = ALICE.balance;

    vm.prank(ALICE);
    omnibusA.reclaim(reclaimLock, aliceTerms, bobTerms);

    assertEq(uint8(omnibusA.lockState(reclaimLock)), uint8(LockState.Spent));
    // Chain B still committed (independent)
    assertEq(uint8(omnibusB.lockState(reclaimLock)), uint8(LockState.Committed));
    assertEq(tokenA.balanceOf(ALICE) - aliceTokenBefore, tokenAAmount);
    assertEq(ALICE.balance - aliceEthBefore, collateralAmount);

    // === RECLAIM ON CHAIN B ===
    vm.chainId(CHAIN_B);
    uint256 bobTokenBefore = tokenB.balanceOf(BOB);
    uint256 bobEthBefore = BOB.balance;

    vm.prank(BOB);
    omnibusB.reclaim(reclaimLock, bobTerms, aliceTerms);

    assertEq(uint8(omnibusB.lockState(reclaimLock)), uint8(LockState.Spent));
    assertEq(tokenB.balanceOf(BOB) - bobTokenBefore, tokenBAmount);
    assertEq(BOB.balance - bobEthBefore, collateralAmount);

    // Both omnibus contracts empty
    assertEq(tokenA.balanceOf(address(omnibusA)), 0);
    assertEq(tokenB.balanceOf(address(omnibusB)), 0);
  }

  // ============ Scenario 5: Same-Chain Reclaim Before Deadline ============

  /// @notice Test same-chain reclaim before deadline (mutual cancel)
  function test_scenario_sameChain_reclaimBeforeDeadline_mutualCancel() public {
    uint256 assetAmount = 1 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Alice commits -> Free
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    // Bob commits -> Committed
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));

    // Warp to just before deadline
    vm.warp(deadline - 1);

    // Record balances
    uint256 aliceBalBefore = ALICE.balance;
    uint256 bobBalBefore = BOB.balance;

    // Alice reclaims
    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    // Verify: lock state = Spent
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // Verify: ALICE received her assets + collateral
    assertEq(ALICE.balance - aliceBalBefore, assetAmount + collateralAmount);

    // Verify: BOB received his assets + collateral
    assertEq(BOB.balance - bobBalBefore, assetAmount + collateralAmount);

    // Omnibus should be empty
    assertEq(address(omnibus).balance, 0);
  }

  // ============ Scenario 6: Reclaim From Committed State (Cross-Chain) ============

  /// @notice Test reclaim from cross-chain Committed state (only Alice's side)
  function test_scenario_reclaimFromCommitted_crossChain_success() public {
    // Use cross-chain terms so reclaim only processes party's assets
    uint256 assetAmount = 1 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Bob's terms on different chain - Alice can reclaim her assets independently
    Terms memory bobTerms = TermsHelper.makeTerms(
      CHAIN_B, // Different chain
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Alice commits -> Committed (cross-chain goes directly to Committed)
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));

    // Bob doesn't commit on Chain B (simulated by not calling commit)

    // Record Alice's balance
    uint256 aliceBalBefore = ALICE.balance;

    // Alice reclaims from Committed state
    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    // Verify: lock state = Spent
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // Verify: ALICE received her assets + collateral
    assertEq(ALICE.balance - aliceBalBefore, assetAmount + collateralAmount);

    // Bob had nothing locked on this chain
    // Omnibus should be empty
    assertEq(address(omnibus).balance, 0);
  }

  // ============ Internal Helpers ============

  function _mintTokensTo(address account) internal {
    mockERC20.mint(account, 1_000_000 ether);
    mockERC1155.mint(account, 1, 10000, '');
    mockERC1155.mint(account, 2, 10000, '');
  }

  function _approveAllForOmnibus(address owner, OmnibusHarness target) internal {
    vm.startPrank(owner);
    mockERC20.approve(address(target), type(uint256).max);
    mockERC721.setApprovalForAll(address(target), true);
    mockERC1155.setApprovalForAll(address(target), true);
    vm.stopPrank();
  }
}
