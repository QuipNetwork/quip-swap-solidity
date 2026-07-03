// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../TermsLib.sol';

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
/// @dev the signature is a SOFT GUARD: it proves this exact payload (lock + both
/// terms, on this chain, for this contract) was endorsed by the declared identity —
/// it does NOT gate which identity may post a side. Counterparty-identity checks,
/// where a client wants them, happen off-chain against the Commitment event
struct CommitAuth {
  /// @notice the committing side's identity blob (routes + verifies)
  /// @dev length < 20 reverts MalformedSigner; length == 20 is an address
  /// (self-auth / EOA ecrecover / ERC-1271 by code presence); length > 20 is
  /// an ERC-7913 keyed identity: verifier(20 bytes) ‖ key
  bytes signer;
  /// @notice signature over commitDigest; '0x' for self-auth
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

  /// @notice thrown when a signer blob is shorter than 20 bytes
  error MalformedSigner();

  /// @notice thrown on the keyed route when the verifier is not allowlisted
  error UntrustedVerifier();

  /// @notice thrown when the routed verification machine rejects the signature
  error InvalidCommitSignature();

  /// @notice emitted when commitment fee is updated
  /// @param oldFee the previous fee
  /// @param newFee the new fee
  event FeeUpdated(uint256 oldFee, uint256 newFee);

  /// @notice emitted when accumulated fees are withdrawn
  /// @param to the recipient address
  /// @param amount the amount withdrawn
  event FeesWithdrawn(address indexed to, uint256 amount);

  /// @notice emitted when a verifier's trust status changes
  /// @param verifier the ERC-7913 verifier address
  /// @param trusted whether the verifier is now trusted
  event VerifierTrustUpdated(address indexed verifier, bool trusted);

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

  /// @notice returns the state of a lock
  /// @param lock the hashlock identifier
  /// @return state the lock state
  function lockState(bytes32 lock) external view returns (LockState state);

  /// @notice returns the terms hash for a lock
  /// @param lock the hashlock identifier
  /// @return canonicalDigest the canonical terms hash
  function termsHash(bytes32 lock) external view returns (bytes32 canonicalDigest);

  /// @notice returns whether a side was posted for a lock
  /// @param lock the hashlock identifier
  /// @param termsDigest the side's terms digest
  /// @return isPosted whether that side has been posted
  function posted(bytes32 lock, bytes32 termsDigest) external view returns (bool isPosted);

  /// @notice returns whether an ERC-7913 verifier is trusted for the keyed route
  /// @param verifier the verifier address
  /// @return trusted whether the verifier is allowlisted
  function trustedVerifiers(address verifier) external view returns (bool trusted);

  /// @notice sets the trust status of an ERC-7913 verifier (owner only)
  /// @param verifier the verifier address (non-zero)
  /// @param trusted the new trust status
  function setVerifierTrust(address verifier, bool trusted) external;

  /// @notice the domain tag bound into every commit digest
  /// @return tag keccak256('QUIP:Omnibus:commit:v1')
  function COMMIT_DIGEST_TAG() external view returns (bytes32 tag);

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
  /// @dev permissionless: any sender may commit; the identity in `auth`
  /// AUTHENTICATES the payload while msg.sender FUNDS the leg + fee. The
  /// signature is over commitDigest; self-auth (msg.sender == 20-byte signer)
  /// requires no signature
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
  /// @dev a cross-chain claim is gated only on the local (party) leg's deadline; the
  /// counterparty leg's deadline is enforced only when it settles on this chain too.
  /// for a cross-chain swap the secret holder claims the counterparty's leg first, so
  /// the leg the secret holder claims must expire BEFORE the other leg: set the secret
  /// holder's own deposit with the later deadline and the counterparty's deposit (the
  /// one the secret holder takes) with the earlier deadline. the gap between the two is
  /// the buffer the second claimant has after the secret is revealed; mis-ordering it
  /// lets the secret holder take both legs
  /// @param secret the preimage of the lock
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function claim(bytes32 secret, Terms calldata party, Terms calldata counterparty) external;

  /// @notice reclaims assets after deadline expires
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
