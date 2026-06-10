// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, Terms} from '../../../src/TermsLib.sol';
import {LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../../harness/OmnibusHarness.sol';
import {ERC20Mock} from '../../mocks/ERC20Mock.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus Happy Path Scenarios
/// @dev Successful swap flows under the windowed timing model. Inherits the canonical
///      schedule, actors, and helpers from OmnibusTest (Alice = proposer, Bob = taker);
///      adds per-chain instances and fresh tokens for the cross-chain legs. The base
///      pre-funding of the harness is zeroed so scenarios can assert exact end-to-end
///      contract-balance accounting.
contract Omnibus_HappyPath is OmnibusTest {
  using AssetHelper for *;

  // ============ Scenario Fixtures ============

  uint256 public constant CHAIN_A = 1;
  uint256 public constant CHAIN_B = 137;

  OmnibusHarness public omnibusA;
  OmnibusHarness public omnibusB;
  ERC20Mock public tokenA;
  ERC20Mock public tokenB;
  address public TREASURY;

  function setUp() public override {
    super.setUp();

    // scenarios assert exact contract-balance accounting; drop the base pre-funding
    vm.deal(address(omnibus), 0);

    // actors are already registered on the base quipFactory; reuse it on both chains
    omnibusA = new OmnibusHarness(address(this), address(quipFactory));
    omnibusB = new OmnibusHarness(address(this), address(quipFactory));
    tokenA = new ERC20Mock('TokenA', 'TKA', 18);
    tokenB = new ERC20Mock('TokenB', 'TKB', 18);
    TREASURY = makeAddr('treasury');
  }

  // ============ Scenario 1: Same-Chain Native Swap ============

  function test_scenario_sameChain_nativeSwap_success() public {
    uint256 aliceAssetAmount = 1 ether;
    uint256 bobAssetAmount = 0.5 ether;

    Terms memory aliceTerms = _aliceTermsOn(block.chainid, _makeNativeAssets(aliceAssetAmount));
    Terms memory bobTerms = _bobTermsOn(block.chainid, _makeNativeAssets(bobAssetAmount));

    // Step 1: Alice (proposer) commits first (same-chain -> Free state)
    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: aliceAssetAmount}(lock, aliceTerms, bobTerms);
    _assertLockState(lock, LockState.Free);

    // Step 2: Bob (taker) commits second (same-chain -> Committed state)
    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: bobAssetAmount}(lock, bobTerms, aliceTerms);
    _assertLockState(lock, LockState.Committed);

    uint256 bobRecipientBalBefore = BOB_RECIPIENT.balance;
    uint256 aliceRecipientBalBefore = ALICE_RECIPIENT.balance;

    // Step 3: settle with the secret in the proposer-claim window
    _warpToProposerClaim();
    vm.prank(CHARLIE);
    omnibus.claim(SECRET, aliceTerms, bobTerms);

    _assertLockState(lock, LockState.Spent);
    // BOB_RECIPIENT received Alice's assets
    assertEq(BOB_RECIPIENT.balance - bobRecipientBalBefore, aliceAssetAmount);
    // ALICE_RECIPIENT received Bob's assets
    assertEq(ALICE_RECIPIENT.balance - aliceRecipientBalBefore, bobAssetAmount);
    assertEq(address(omnibus).balance, 0);
  }

  // ============ Scenario 2: Same-Chain Mixed Assets Swap ============

  function test_scenario_sameChain_mixedAssets_success() public {
    (Terms memory aliceTerms, Terms memory bobTerms) = _buildMixedAssetTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: 1 ether}(lock, aliceTerms, bobTerms);
    _assertLockState(lock, LockState.Free);

    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bobTerms, aliceTerms);
    _assertLockState(lock, LockState.Committed);

    uint256 bobRecipientEthBefore = BOB_RECIPIENT.balance;
    uint256 bobRecipientERC20Before = mockERC20.balanceOf(BOB_RECIPIENT);
    uint256 aliceRecipient1155Before = mockERC1155.balanceOf(ALICE_RECIPIENT, ERC1155_TOKEN_ID);

    _warpToProposerClaim();
    omnibus.claim(SECRET, aliceTerms, bobTerms);

    // BOB_RECIPIENT received 1 ETH + 100 ERC20 (Alice's assets)
    assertEq(BOB_RECIPIENT.balance - bobRecipientEthBefore, 1 ether);
    assertEq(mockERC20.balanceOf(BOB_RECIPIENT) - bobRecipientERC20Before, 100 ether);
    // ALICE_RECIPIENT received 10 ERC1155 (Bob's assets)
    assertEq(mockERC1155.balanceOf(ALICE_RECIPIENT, ERC1155_TOKEN_ID) - aliceRecipient1155Before, 10);
  }

  function _buildMixedAssetTerms() internal view returns (Terms memory aliceTerms, Terms memory bobTerms) {
    Asset[] memory aliceAssets = new Asset[](2);
    aliceAssets[0] = _makeNativeAsset(1 ether);
    aliceAssets[1] = _makeERC20Asset(100 ether);
    aliceTerms = _aliceTermsOn(block.chainid, aliceAssets);

    bobTerms = _bobTermsOn(block.chainid, _makeERC1155Assets(ERC1155_TOKEN_ID, 10));
  }

  // ============ Scenario 3: Cross-Chain Complete Swap ============

  function test_scenario_crossChain_completeSwap_success() public {
    bytes32 secret = keccak256('crosschain-secret');
    bytes32 crossLock = omnibus.exposed_generateLock(secret);
    uint256 tokenAAmount = 100 ether;
    uint256 tokenBAmount = 200 ether;

    tokenA.mint(ALICE, tokenAAmount);
    tokenB.mint(BOB, tokenBAmount);

    Terms memory aliceTerms = _aliceTermsOn(CHAIN_A, AssetHelper.makeERC20(address(tokenA), tokenAAmount).toArray());
    Terms memory bobTerms = _bobTermsOn(CHAIN_B, AssetHelper.makeERC20(address(tokenB), tokenBAmount).toArray());

    // Alice commits on Chain A (proposer window)
    vm.chainId(CHAIN_A);
    vm.prank(ALICE);
    tokenA.approve(address(omnibusA), tokenAAmount);
    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibusA.commit(crossLock, aliceTerms, bobTerms);
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Committed));
    assertEq(tokenA.balanceOf(address(omnibusA)), tokenAAmount);

    // Bob commits on Chain B (taker window)
    vm.chainId(CHAIN_B);
    vm.prank(BOB);
    tokenB.approve(address(omnibusB), tokenBAmount);
    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibusB.commit(crossLock, bobTerms, aliceTerms);
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Committed));
    assertEq(tokenB.balanceOf(address(omnibusB)), tokenBAmount);

    // Alice reveals the secret on Chain B, claiming Bob's leg (proposer-claim window)
    vm.chainId(CHAIN_B);
    _warpToProposerClaim();
    uint256 aliceRecipientTokenBefore = tokenB.balanceOf(ALICE_RECIPIENT);
    omnibusB.claim(secret, aliceTerms, bobTerms);
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Spent));
    assertEq(tokenB.balanceOf(ALICE_RECIPIENT) - aliceRecipientTokenBefore, tokenBAmount);

    // Bob uses the revealed secret on Chain A, claiming Alice's leg (taker-claim window)
    vm.chainId(CHAIN_A);
    _warpToTakerClaim();
    uint256 bobRecipientTokenBefore = tokenA.balanceOf(BOB_RECIPIENT);
    omnibusA.claim(secret, bobTerms, aliceTerms);
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Spent));
    assertEq(tokenA.balanceOf(BOB_RECIPIENT) - bobRecipientTokenBefore, tokenAAmount);

    assertEq(tokenA.balanceOf(address(omnibusA)), 0);
    assertEq(tokenB.balanceOf(address(omnibusB)), 0);
  }

  // ============ Scenario 4: Cross-Chain Reclaim ============

  function test_scenario_crossChain_reclaimBothChains_success() public {
    bytes32 secret = keccak256('reclaim-secret');
    bytes32 reclaimLock = omnibus.exposed_generateLock(secret);
    uint256 tokenAAmount = 100 ether;
    uint256 tokenBAmount = 200 ether;

    tokenA.mint(ALICE, tokenAAmount);
    tokenB.mint(BOB, tokenBAmount);

    Terms memory aliceTerms = _aliceTermsOn(CHAIN_A, AssetHelper.makeERC20(address(tokenA), tokenAAmount).toArray());
    Terms memory bobTerms = _bobTermsOn(CHAIN_B, AssetHelper.makeERC20(address(tokenB), tokenBAmount).toArray());

    // Commits
    vm.chainId(CHAIN_A);
    vm.warp(AT_PROPOSER_COMMIT);
    vm.startPrank(ALICE);
    tokenA.approve(address(omnibusA), tokenAAmount);
    omnibusA.commit(reclaimLock, aliceTerms, bobTerms);
    vm.stopPrank();

    vm.chainId(CHAIN_B);
    vm.warp(AT_TAKER_COMMIT);
    vm.startPrank(BOB);
    tokenB.approve(address(omnibusB), tokenBAmount);
    omnibusB.commit(reclaimLock, bobTerms, aliceTerms);
    vm.stopPrank();

    // Reclaim on Chain A after Alice's reclaim release
    vm.chainId(CHAIN_A);
    _warpToProposerReclaim();
    uint256 aliceTokenBefore = tokenA.balanceOf(ALICE);
    vm.prank(ALICE);
    omnibusA.reclaim(reclaimLock, aliceTerms, bobTerms);
    assertEq(uint8(omnibusA.lockState(reclaimLock)), uint8(LockState.Spent));
    assertEq(tokenA.balanceOf(ALICE) - aliceTokenBefore, tokenAAmount);

    // Reclaim on Chain B after Bob's reclaim release
    vm.chainId(CHAIN_B);
    _warpToTakerReclaim();
    uint256 bobTokenBefore = tokenB.balanceOf(BOB);
    vm.prank(BOB);
    omnibusB.reclaim(reclaimLock, bobTerms, aliceTerms);
    assertEq(uint8(omnibusB.lockState(reclaimLock)), uint8(LockState.Spent));
    assertEq(tokenB.balanceOf(BOB) - bobTokenBefore, tokenBAmount);

    assertEq(tokenA.balanceOf(address(omnibusA)), 0);
    assertEq(tokenB.balanceOf(address(omnibusB)), 0);
  }

  // ============ Scenario 5: Same-Chain Reclaim After Release ============

  function test_scenario_sameChain_reclaimAfterDeadline_mutualCancel() public {
    uint256 assetAmount = 1 ether;

    Terms memory aliceTerms = _aliceTermsOn(block.chainid, _makeNativeAssets(assetAmount));
    Terms memory bobTerms = _bobTermsOn(block.chainid, _makeNativeAssets(assetAmount));

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount}(lock, aliceTerms, bobTerms);
    _assertLockState(lock, LockState.Free);

    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount}(lock, bobTerms, aliceTerms);
    _assertLockState(lock, LockState.Committed);

    // Proposer reclaim after release refunds both sides
    _warpToProposerReclaim();
    uint256 aliceBalBefore = ALICE.balance;
    uint256 bobBalBefore = BOB.balance;

    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    _assertLockState(lock, LockState.Spent);
    assertEq(ALICE.balance - aliceBalBefore, assetAmount);
    assertEq(BOB.balance - bobBalBefore, assetAmount);
    assertEq(address(omnibus).balance, 0);
  }

  // ============ Scenario 6: Reclaim From Committed State (Cross-Chain) ============

  function test_scenario_reclaimFromCommitted_crossChain_success() public {
    uint256 assetAmount = 1 ether;

    Terms memory aliceTerms = _aliceTermsOn(block.chainid, _makeNativeAssets(assetAmount));
    // Bob's terms on a different chain
    Terms memory bobTerms = _bobTermsOn(CHAIN_B, _makeNativeAssets(assetAmount));

    // Alice commits -> Committed (cross-chain goes directly to Committed)
    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount}(lock, aliceTerms, bobTerms);
    _assertLockState(lock, LockState.Committed);

    // Alice reclaims from Committed state after her release
    _warpToProposerReclaim();
    uint256 aliceBalBefore = ALICE.balance;
    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    _assertLockState(lock, LockState.Spent);
    assertEq(ALICE.balance - aliceBalBefore, assetAmount);
    assertEq(address(omnibus).balance, 0);
  }

  // ============ Scenario 7: Fee-Inclusive Settlement ============

  /// @notice with a nonzero commitment fee, payouts carry exactly the declared asset amounts,
  ///         the fees accrue separately, and withdrawing them empties the contract to zero
  function test_scenario_sameChain_withFee_settleAndWithdraw() public {
    uint256 fee = 0.005 ether;
    omnibus.setCommitmentFee(fee);

    uint256 aliceAssetAmount = 1 ether;
    uint256 bobAssetAmount = 0.5 ether;
    Terms memory aliceTerms = _aliceTermsOn(block.chainid, _makeNativeAssets(aliceAssetAmount));
    Terms memory bobTerms = _bobTermsOn(block.chainid, _makeNativeAssets(bobAssetAmount));

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: aliceAssetAmount + fee}(lock, aliceTerms, bobTerms);

    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: bobAssetAmount + fee}(lock, bobTerms, aliceTerms);

    assertEq(omnibus.accruedFees(), 2 * fee);

    _warpToProposerClaim();
    vm.prank(ALICE);
    omnibus.claim(SECRET, aliceTerms, bobTerms);

    // recipients receive exactly the declared asset amounts; fees never leak into payouts
    assertEq(BOB_RECIPIENT.balance, aliceAssetAmount);
    assertEq(ALICE_RECIPIENT.balance, bobAssetAmount);
    assertEq(address(omnibus).balance, 2 * fee);
    assertEq(omnibus.accruedFees(), 2 * fee);

    // withdrawing the accrued fees leaves the contract exactly empty
    omnibus.withdrawFees(TREASURY);
    assertEq(TREASURY.balance, 2 * fee);
    assertEq(address(omnibus).balance, 0);
  }

  // ============ Scenario 8: Fee-Inclusive Reclaim ============

  /// @notice reclaim refunds exactly the escrowed assets — never the commitment fees, which
  ///         stay accrued and withdrawable
  function test_scenario_sameChain_withFee_reclaimRefundsEscrowNotFee() public {
    uint256 fee = 0.005 ether;
    omnibus.setCommitmentFee(fee);

    uint256 assetAmount = 1 ether;
    Terms memory aliceTerms = _aliceTermsOn(block.chainid, _makeNativeAssets(assetAmount));
    Terms memory bobTerms = _bobTermsOn(block.chainid, _makeNativeAssets(assetAmount));

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + fee}(lock, aliceTerms, bobTerms);

    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + fee}(lock, bobTerms, aliceTerms);

    _warpToProposerReclaim();
    uint256 aliceBalBefore = ALICE.balance;
    uint256 bobBalBefore = BOB.balance;

    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    // each side gets back exactly its escrowed assets, not the fee it paid
    assertEq(ALICE.balance - aliceBalBefore, assetAmount);
    assertEq(BOB.balance - bobBalBefore, assetAmount);
    assertEq(omnibus.accruedFees(), 2 * fee);
    assertEq(address(omnibus).balance, 2 * fee);

    omnibus.withdrawFees(TREASURY);
    assertEq(address(omnibus).balance, 0);
  }
}
