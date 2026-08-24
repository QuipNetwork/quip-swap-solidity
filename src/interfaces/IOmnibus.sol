// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../TermsLib.sol';
import {IWalletFactory} from './IWalletFactory.sol';

/// @notice the lock state for Omnibus swaps
enum LockState {
  /// @notice default - lock has never been used
  Unused,
  /// @notice same-chain only: one party has committed, waiting for counterparty
  Free,
  /// @notice ready for execute (same-chain: both committed; cross-chain: single commit)
  Committed,
  /// @notice terminal (executed or reclaimed)
  Spent
}

/// @notice auth data for one commit; identities attribute, they don't gate
/// @dev the endorsement is a SOFT GUARD: it proves this exact payload (lock + both
/// terms, on this chain, for this contract) was endorsed by the declared identity —
/// it does NOT gate which identity may post a side. Counterparty-identity checks,
/// where a client wants them, happen off-chain against the Commitment event.
/// Two routes, discriminated by `signature`:
/// - non-empty: KEYED route — `signature` is verified over commitDigest by the
///   declared verifier
/// - empty: WALLET route — msg.sender must be a wallet deployed by the quip
///   WalletFactory (vaultIdOf(msg.sender) != 0). No signature is verified on
///   this route: a vetted wallet implementation only reaches commit from its
///   PQ-authenticated execute flow, so factory membership stands in for the
///   endorsement. The declared identity is ATTRIBUTION ONLY here — it is NOT
///   cryptographically proven to have endorsed the payload. The
///   permissionless-sender model collapses to sender == quip wallet on this
///   route
struct CommitAuth {
  /// @notice the committing side's identity blob
  /// @dev the ONLY accepted shape is an ERC-7913 keyed identity:
  /// verifier(20 bytes) ‖ key; length <= 20 reverts MalformedSigner
  bytes signer;
  /// @notice signature over commitDigest, verified by the declared verifier;
  /// EMPTY selects the wallet route
  bytes signature;
}

interface IOmnibus {
  /// @notice thrown when expected and actual terms hashes do not match
  error TermsMismatch();

  /// @notice thrown when the lock state is not as expected
  error InvalidLockState();

  /// @notice thrown when native amount received does not match expected
  error IncorrectNativeAmountReceived();

  /// @notice thrown when lock state transition is not allowed
  error InvalidLockAdvancement();

  /// @notice thrown when a commit would re-post an already-posted side
  error TermsAlreadyPosted();

  /// @notice thrown when paying out a side that was never posted for the lock
  error TermsNotPosted();

  /// @notice thrown when fee exceeds MAX_FEE
  error FeeExceedsMax();

  /// @notice thrown when a verifier address is zero
  error ZeroVerifier();

  /// @notice thrown at construction when the wallet factory address is zero
  error ZeroFactory();

  /// @notice thrown at construction when the version label is zero
  error ZeroVersion();

  /// @notice thrown when a signer blob is not an ERC-7913 keyed identity (20 bytes or shorter)
  error MalformedSigner();

  /// @notice thrown when the declared verifier is not active
  error VerifierNotActive();

  /// @notice thrown when the verifier rejects the signature
  error InvalidCommitSignature();

  /// @notice thrown on the wallet route when msg.sender is not a wallet
  /// deployed by the quip WalletFactory
  error NotQuipWallet();

  /// @notice emitted when commitment fee is updated
  /// @param oldFee the previous fee
  /// @param newFee the new fee
  event FeeUpdated(uint256 oldFee, uint256 newFee);

  /// @notice emitted when accumulated fees are withdrawn
  /// @param to the recipient address
  /// @param amount the amount withdrawn
  event FeesWithdrawn(address indexed to, uint256 amount);

  /// @notice emitted when a verifier's activity status changes
  /// @param verifier the ERC-7913 verifier address
  /// @param active whether the verifier is now active
  event VerifierActivityUpdated(address indexed verifier, bool active);

  /// @notice emitted when a party commits to a swap
  /// @param lock the hashlock identifier
  /// @param party the terms of the committing party
  /// @param signer the identity blob that endorsed this commit (attribution)
  /// @param sender the address that submitted and FUNDED the commit
  event Commitment(bytes32 indexed lock, Terms party, bytes signer, address indexed sender);

  /// @notice emitted when a swap is executed
  /// @param recipient address receiving assets of claim
  /// @param lock the hashlock identifier
  /// @param secret the preimage that unlocked the swap
  event Claim(address recipient, bytes32 indexed lock, bytes32 secret);

  /// @notice emitted when a party reclaims their assets
  /// @param caller address which initiated reclaim
  /// @param lock the hashlock identifier
  /// @param recipient the address that received the reclaim
  event Reclaimed(address caller, bytes32 indexed lock, address indexed recipient);

  /// @notice returns the state of a swap
  /// @dev state is keyed by swap id, not by bare lock: swapId =
  /// keccak256(abi.encodePacked(lock, canonicalTermsDigest)), where
  /// canonicalTermsDigest is TermsLib.digestTermsCanonically over the pairing.
  /// binding the key to the negotiated terms means an unrelated pairing reusing
  /// an observed lock occupies its own slot and cannot block or alter another
  /// swap's state
  /// @param swapId the swap identifier
  /// @return state the lock state
  function lockState(bytes32 swapId) external view returns (LockState state);

  /// @notice returns the canonical terms digest recorded for a swap
  /// @dev keyed by swap id (see lockState); nonzero iff the pairing has been
  /// committed on this chain, and then always equal to the digest the swap id
  /// itself was derived from
  /// @param swapId the swap identifier
  /// @return canonicalDigest the canonical hash of the swap's term pairing
  function termsHash(bytes32 swapId) external view returns (bytes32 canonicalDigest);

  /// @notice returns whether a side was posted for a swap
  /// @dev keyed by swap id (see lockState)
  /// @param swapId the swap identifier
  /// @param termsDigest the digest of the side's terms
  /// @return isPosted whether that side has been committed
  function posted(bytes32 swapId, bytes32 termsDigest) external view returns (bool isPosted);

  /// @notice returns whether an ERC-7913 verifier is active for the keyed route
  /// @param verifier the verifier address
  /// @return active whether the verifier is active
  function verifierActive(address verifier) external view returns (bool active);

  /// @notice sets the activity status of an ERC-7913 verifier (owner only)
  /// @param verifier the verifier address (non-zero)
  /// @param active the new activity status
  function setVerifierActivity(address verifier, bool active) external;

  /// @notice the protocol tag bound into the commit-digest domain separator
  /// @return tag keccak256('QUIP:Omnibus:commit')
  function COMMIT_DIGEST_TAG() external view returns (bytes32 tag);

  /// @notice the commit-digest domain separator, baked at construction:
  /// keccak256(abi.encode(COMMIT_DIGEST_TAG, block.chainid, address(this)))
  /// @return separator the domain separator
  function DOMAIN_SEPARATOR() external view returns (bytes32 separator);

  /// @notice the quip WalletFactory whose deployments the wallet route trusts,
  /// baked immutably at construction (the factory proxy address is permanent)
  /// @return factory the wallet factory registry
  function WALLET_FACTORY() external view returns (IWalletFactory factory);

  /// @notice computes the swap id binding a lock to a term pairing
  /// @dev the key all swap state (lockState, termsHash, posted) is stored under:
  /// keccak256(abi.encodePacked(lock, canonicalTermsDigest)), with
  /// canonicalTermsDigest = TermsLib.digestTermsCanonically over the pairing —
  /// so the result is independent of which side is passed as `party` vs
  /// `counterparty`
  /// @param lock the hashlock identifier
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  /// @return id the swap identifier
  function swapId(bytes32 lock, Terms calldata party, Terms calldata counterparty) external pure returns (bytes32 id);

  /// @notice computes the digest a committer's identity must sign
  /// @dev pure function of caller-known data; the SDK computes it locally and
  /// commit recomputes it from calldata — it is never transmitted. Binds the
  /// full context: chainid + this contract (replay scope), lock, both terms,
  /// and the declared identity (signerHash = keccak256 of the WHOLE blob)
  /// @param lock the hashlock identifier
  /// @param party the committing side's terms
  /// @param counterparty the other side's terms
  /// @param signerHash keccak256 of the committing side's identity blob
  /// @return digest the 32-byte commit digest
  function commitDigest(
    bytes32 lock,
    Terms calldata party,
    Terms calldata counterparty,
    bytes32 signerHash
  ) external view returns (bytes32 digest);

  /// @notice commits assets and collateral to a swap
  /// @dev permissionless: any sender may commit; the ERC-7913 keyed identity in
  /// `auth` AUTHENTICATES the payload while msg.sender FUNDS the leg + fee. With
  /// a non-empty auth.signature it is verified over commitDigest by the declared
  /// verifier; with an empty auth.signature msg.sender must be a wallet deployed
  /// by the quip WalletFactory (see CommitAuth — on that route the identity is
  /// attribution only, not a proven endorsement)
  ///
  /// TOKEN COMPATIBILITY / FUND-LOSS WARNING: escrow accounting assumes balances
  /// change only via transfers. Fee-on-transfer, deflationary, and rounding-lossy
  /// tokens (e.g. stETH's 1-2 wei transfer corner) are rejected at commit by
  /// exact-receipt reconciliation (UnexpectedAmountReceived). Balance-mutable
  /// tokens — rebasing, slashable, admin-burnable — and transfer-blockable tokens
  /// (blacklisting, pausable) are UNSUPPORTED: a post-commit balance reduction
  /// makes claim revert (see claim), positive rebases strand the accrued yield in
  /// the contract with no recovery path, and a token that blocks transfers can
  /// freeze every asset escrowed in the same terms. Escrow the non-rebasing
  /// wrapper instead (e.g. wstETH, not stETH)
  /// @param lock the hashlock identifier
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  /// @param auth the committing side's identity blob and signature
  function commit(
    bytes32 lock,
    Terms calldata party,
    Terms calldata counterparty,
    CommitAuth calldata auth
  ) external payable;

  /// @notice executes the swap by revealing the secret
  /// @dev permissionless: anyone holding the secret may claim, and the transaction
  /// makes the secret public. the counterparty leg is the leg being claimed and must
  /// be on this chain; a same-chain claim settles BOTH legs atomically.
  ///
  /// the enforced window derives from the terms themselves — the proposer is the side
  /// with the earlier commitment deadline — never from which side is passed as `party`
  /// vs `counterparty`, so submitting the terms role-swapped cannot select a different
  /// window. which window applies depends only on whose assets this chain holds:
  /// - the taker's assets are here (every same-chain claim, and the proposer's
  ///   cross-chain leg): the proposer's reveal window
  ///   [taker.commitmentDeadline, proposer.claimDeadline)
  /// - only the proposer's assets are here (the cross-chain taker leg): the taker's
  ///   redeem window [proposer.claimDeadline, proposer.reclaimRelease)
  ///
  /// the redeem window's width, proposer.reclaimRelease - proposer.claimDeadline, is
  /// the cross-chain taker's reaction buffer after the secret is revealed; size it to
  /// cover finality and downtime, since a missed redeem strands the taker's leg until
  /// its reclaimRelease.
  ///
  /// FUND-LOSS WARNING: in a cross-chain swap the secret holder MUST be the proposer.
  /// a taker who knows the secret can withhold their own commitment, wait for the
  /// redeem window on the proposer's chain, and take the proposer's leg while giving
  /// nothing — the contract cannot verify the remote leg, so this is enforceable only
  /// off-chain when the terms are negotiated
  ///
  /// claim payouts are exact-or-revert: it never pays less than the declared
  /// amounts, so revealing the secret is conditional on receiving exactly what was
  /// priced (a clamped claim would let a balance-mutable token's shortfall buy the
  /// secret at a discount). If the pooled escrow was externally reduced (negative
  /// rebase, slash), claim reverts and the swap falls through to reclaim, which
  /// clamps — the trade aborts, but no funds are frozen
  /// @param secret the preimage of the lock
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function claim(bytes32 secret, Terms calldata party, Terms calldata counterparty) external;

  /// @notice reclaims assets after deadline expires
  /// @dev permissionless: assets go to the terms' reclaimRecipient regardless of
  /// caller. Valid from party.reclaimRelease onward; when the counterparty leg is
  /// also local and the lock is Committed, one call returns BOTH legs.
  ///
  /// reclaim is the terminal backstop — nothing exists after it — so it must never
  /// brick: fungible (ERC20/ERC1155) payouts are clamped to the balance actually
  /// held (TermsLib.transferAssetsClamped). With well-behaved tokens the clamp
  /// never engages; it only matters when a balance-mutable token shrank the pooled
  /// escrow in place. Loss allocation across swaps pooled in the same token is
  /// first-come-first-served: earlier reclaims are paid the declared amounts in
  /// full and the last is paid the remainder
  /// @param lock the hashlock identifier
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function reclaim(bytes32 lock, Terms calldata party, Terms calldata counterparty) external;

  /// @notice the maximum allowed commitment fee
  /// @return the max fee in wei
  function MAX_FEE() external view returns (uint256);

  /// @notice the current commitment fee
  /// @return the fee in wei
  function commitmentFee() external view returns (uint256);

  /// @notice the accumulated commitment fees available to withdraw
  /// @return fees the accrued fees in wei
  function accruedFees() external view returns (uint256 fees);

  /// @notice sets the commitment fee (owner only)
  /// @param newFee the new fee (must be <= MAX_FEE)
  function setCommitmentFee(uint256 newFee) external;

  /// @notice withdraws accumulated fees to recipient (owner only)
  /// @param to the recipient address
  function withdrawFees(address to) external;
}
