// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from './TermsLib.sol';
import {CommitAuth, IOmnibus, LockState} from './interfaces/IOmnibus.sol';
import {IWalletFactory} from './interfaces/IWalletFactory.sol';
import {Ownable, Ownable2Step} from '@openzeppelin-contracts-5.6.0-rc.1/access/Ownable2Step.sol';
import {IERC1155Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155Receiver.sol';
import {IERC721Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721Receiver.sol';
import {IERC165} from '@openzeppelin-contracts-5.6.0-rc.1/utils/introspection/IERC165.sol';
import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

/// @title Omnibus
/// @notice Singleton contract for cross-chain swaps using hashlock
contract Omnibus is IOmnibus, IERC721Receiver, IERC1155Receiver, Ownable2Step {
  using TermsLib for Terms;

  /// @notice the salt version label this Omnibus was deployed under, as a
  /// right-padded ASCII word (read it with `cast --to-ascii`)
  ///
  /// @dev IMMUTABLE, and set from the SAME constant the deploy script feeds to
  /// the CREATE3 salt — so the contract states which deployment family it
  /// belongs to, on-chain, without an archaeology dig through broadcast logs.
  ///
  /// This exists because a CREATE3 address ignores init code: the address alone
  /// proves nothing about WHAT is deployed at it, which is how two testnet
  /// deployments ended up wired to the wrong WalletFactory without anything
  /// visibly wrong. VERSION plus WALLET_FACTORY makes a live contract
  /// self-describing — `_requireOurOmnibusAt` checks both before a redeploy is
  /// allowed to treat an occupied address as ours.
  bytes32 public immutable VERSION;

  /// @inheritdoc IOmnibus
  uint256 public constant MAX_FEE = 0.01 ether;

  /// @inheritdoc IOmnibus
  /// @dev no version suffix: version scoping comes from address(this) in the
  /// domain — each Omnibus version deploys at a distinct CREATE3 address
  bytes32 public constant COMMIT_DIGEST_TAG = keccak256('QUIP:Omnibus:commit');

  /// @inheritdoc IOmnibus
  /// @dev baked once at construction from the deploy-time chainid + address
  bytes32 public immutable DOMAIN_SEPARATOR;

  /// @inheritdoc IOmnibus
  IWalletFactory public immutable WALLET_FACTORY;

  /// @inheritdoc IOmnibus
  uint256 public commitmentFee;

  /// @inheritdoc IOmnibus
  uint256 public accruedFees;

  /// @inheritdoc IOmnibus
  mapping(bytes32 swapId => LockState state) public lockState;

  /// @inheritdoc IOmnibus
  mapping(bytes32 swapId => bytes32 canonicalDigest) public termsHash;

  /// @inheritdoc IOmnibus
  mapping(bytes32 swapId => mapping(bytes32 termsDigest => bool isPosted)) public posted;

  /// @inheritdoc IOmnibus
  mapping(bytes32 swapId => mapping(bytes32 sideDigest => bool isReclaimed)) public reclaimed;

  /// @inheritdoc IOmnibus
  mapping(address verifier => bool active) public verifierActive;

  /// @notice initializes the contract with an owner and the quip WalletFactory;
  /// verifiers are activated post-deploy via setVerifierActivity
  /// @param initialOwner the address that will own the contract
  /// @param walletFactory the quip WalletFactory proxy the wallet route trusts
  /// @param version the salt version label this deployment is made under,
  /// right-padded ASCII; must match the label the CREATE3 salt derives from
  ///
  /// @dev `version` is deliberately NOT mixed into DOMAIN_SEPARATOR. The
  /// separator already binds `address(this)`, and the address is a function of
  /// the version, so versions are separated by construction — mixing it in
  /// again would change every commit digest and break signatures the SDK
  /// already produces.
  constructor(address initialOwner, address walletFactory, bytes32 version) Ownable(initialOwner) {
    if (walletFactory == address(0)) revert ZeroFactory();
    if (version == bytes32(0)) revert ZeroVersion();
    WALLET_FACTORY = IWalletFactory(walletFactory);
    VERSION = version;
    DOMAIN_SEPARATOR = keccak256(abi.encode(COMMIT_DIGEST_TAG, block.chainid, address(this)));
  }

  /// @notice allows this contract to receive native currency
  receive() external payable {}

  /// @inheritdoc IOmnibus
  function swapId(bytes32 lock, Terms calldata party, Terms calldata counterparty) external pure returns (bytes32) {
    return _swapId(lock, TermsLib.digestTermsCanonically(party, counterparty));
  }

  /// @inheritdoc IOmnibus
  function commitDigest(
    bytes32 lock,
    Terms calldata party,
    Terms calldata counterparty,
    bytes32 signerHash
  ) public view returns (bytes32) {
    return _commitDigest(lock, party.digestTerms(), counterparty.digestTerms(), signerHash);
  }

  /// @inheritdoc IOmnibus
  function commit(
    bytes32 lock,
    Terms calldata party,
    Terms calldata counterparty,
    CommitAuth calldata auth
  ) external payable {
    // commit is PERMISSIONLESS: the identity in `auth` authenticates the payload,
    // msg.sender funds the party's leg + fee (the sender FUNDS, the identity AUTHORIZES)
    // validate both terms (only party.chainId must match current chain)
    party.enforceChainId(block.chainid);
    party.validateTerms();
    counterparty.validateTerms();
    // term pairing validity ensures deadline ordering
    TermsLib.validateTermPairing(party, counterparty);

    if (TermsLib.proposedByParty(party, counterparty)) {
      // if the party is the proposer, then this is the first commitment, so the party's commitment
      // must not have elapsed
      // if the counterparty is the proposer, then **IT IS ASSUMED THAT THE PARTY HAS VALIDATED
      // THAT THE COUNTERPARTY HAS ALREADY COMMITTED**
      TermsLib.enforceWithin(0, party.commitmentDeadline, block.timestamp);
    } else {
      // if the counterparty has proposed, the counterparty's commitment deadline must have elapsed and
      // the party's commitment deadline must not have elapsed
      // NB: the party *MUST* ensure the commitment from the counterparty has taken effect especially if
      // the swap is cross-chain
      TermsLib.enforceWithin(counterparty.commitmentDeadline, party.commitmentDeadline, block.timestamp);
    }

    _enforceCorrectNative(party.totalNative() + commitmentFee);

    bytes32 canonicalDigest = TermsLib.digestTermsCanonically(party, counterparty);
    bytes32 swapId = _swapId(lock, canonicalDigest);
    bytes32 partyDigest = party.digestTerms();

    // single digest code path — same fn the commitDigest view uses (no inline re-derivation)
    _enforceCommitAuthorized(auth, _commitDigest(lock, partyDigest, counterparty.digestTerms(), keccak256(auth.signer)));

    LockState current = lockState[swapId];
    LockState target;

    // invalid states (committed, spent) will revert at _advanceLockTo since is either `Free` or `Committed`
    // and no valid advancement from committed => free.committed or spent => free/committed
    if (current == LockState.Unused) {
      termsHash[swapId] = canonicalDigest;
      target = party.chainId == counterparty.chainId ? LockState.Free : LockState.Committed;
    }
    // no need to check sameness of chain; only way that current == LockState.Free
    // is if the terms had same chain in the previous `commit` call
    if (current == LockState.Free) {
      _enforceSameTerms(termsHash[swapId], canonicalDigest);
      // second same-chain commit must post the other side, not re-post the same one
      if (posted[swapId][partyDigest]) revert TermsAlreadyPosted();
      target = LockState.Committed;
    }

    _advanceLockTo(swapId, current, target);

    // accrue the fee; the rest of msg.value is escrowed native owed back to reclaimRecipients
    accruedFees += commitmentFee;

    // record the side this commit posts
    posted[swapId][partyDigest] = true;

    // transfer non-native assets
    party.transferAssetsNoNative(msg.sender, address(this));

    emit Commitment(lock, party, auth.signer, msg.sender);
  }

  /// @inheritdoc IOmnibus
  function claim(bytes32 secret, Terms calldata party, Terms calldata counterparty) external {
    // it is assumed the msg.sender represents the `party`
    // ie the claim is being done by the party on the counterparty terms
    bytes32 lock = _generateLock(secret);

    // verify terms and state
    bytes32 canonicalDigest = TermsLib.digestTermsCanonically(party, counterparty);
    bytes32 swapId = _swapId(lock, canonicalDigest);
    _enforceSameTerms(termsHash[swapId], canonicalDigest);

    // counterparty terms _MUST_ be on this chainId so that the party may
    // receive the assets; party terms _MAY_ be on this chainId
    counterparty.enforceChainId(block.chainid);

    // terms validated at outset, so roles derive from terms themselves via deadline
    // ordering
    bool isPartyProposer = TermsLib.proposedByParty(party, counterparty);
    Terms calldata proposer = isPartyProposer ? party : counterparty;
    Terms calldata taker = isPartyProposer ? counterparty : party;


    // proposer (secret holder) always claims first
    // proposer's claim window is: [taker.commitmentDeadline, proposer.claimDeadline]
    //
    // same-chain swaps are settled atomically for both parties, therefore 
    // the only window to consider is the proposers claim window
    //
    // cross-chain has a proposer claim leg and taker claim leg
    // proposer claim window is: [taker.commitmentDeadline, proposer.claimDeadline]
    // taker claim window is: [proposer.claimDeadline, proposer.reclaimRelease]
    // 
    // NB: taker's chainId is the chain on which proposer claims
    if (taker.chainId == block.chainid) {
      TermsLib.enforceWithin(taker.commitmentDeadline, proposer.claimDeadline, block.timestamp);
    } else {
      TermsLib.enforceWithin(proposer.claimDeadline, proposer.reclaimRelease, block.timestamp);
    }

    // spend lock
    LockState current = lockState[swapId];
    _enforceCommittedLock(current);

    // marking as spent before any transfer blocks reentrant claims
    _advanceLockTo(swapId, current, LockState.Spent);

    // counterparty's side must have been posted for this lock
    _enforcePosted(swapId, counterparty.digestTerms());

    // counterparty's assets to party's recipient
    counterparty.transferAssets(address(this), party.recipient);
    emit Claim(lock, party.recipient, secret);

    bool isSameChain = party.chainId == counterparty.chainId;

    // same-chain settles both legs atomically: either both transfers succeed or the whole
    // claim reverts, so no one can take their incoming leg without delivering the outgoing one
    if (isSameChain) {
      // party's side must have been posted for this lock
      _enforcePosted(swapId, party.digestTerms());
      // party's assets to counterparty's recipient
      party.transferAssets(address(this), counterparty.recipient);
      emit Claim(lock, counterparty.recipient, secret);
    }
  }

  /// @inheritdoc IOmnibus
  function reclaim(bytes32 lock, Terms calldata party, Terms calldata counterparty) external {
    // it is assumed msg.sender is representing the party
    // reclaim is assumed to be called for party
    party.enforceChainId(block.chainid);

    // validate reclaim in correct window
    // if the party is the proposer, then the party's reclaimRelease must have elapsed
    // if the counterparty is the proposer, then the party's reclaimRelease must have elapsed
    TermsLib.enforceWithin(party.reclaimRelease, type(uint256).max, block.timestamp);

    bytes32 canonicalDigest = TermsLib.digestTermsCanonically(party, counterparty);
    bytes32 swapId = _swapId(lock, canonicalDigest);
    _enforceSameTerms(termsHash[swapId], canonicalDigest);
    // party's side must have been posted for this lock; checked after the terms are
    // proven genuine so the more specific reverts surface first
    _enforcePosted(swapId, party.digestTerms());

    // reclaim returns ONLY the party's own leg to the party's own reclaimRecipient. each
    // side reclaims independently, so a hostile counterparty recipient can never block the
    // party's recovery, and no one can ever receive the counterparty's assets here
    bytes32 partyDigest = party.digestTerms();
    if (reclaimed[swapId][partyDigest]) revert AlreadyReclaimed();

    LockState current = lockState[swapId];
    if (current == LockState.Spent) {
      // a spent lock is reclaimable only mid-reclaim (the counterparty side already reclaimed);
      // a claim-settled lock is spent with no reclaimed flag set, and must not be reclaimable
      if (!reclaimed[swapId][counterparty.digestTerms()]) revert InvalidLockState();
    } else {
      // first reclaim of this swap: Committed or Free -> Spent (reverts on Unused/Spent)
      _advanceLockTo(swapId, current, LockState.Spent);
    }

    reclaimed[swapId][partyDigest] = true;
    party.transferAssetsClamped(party.reclaimRecipient);

    emit Reclaimed(msg.sender, lock, party.reclaimRecipient);
  }

  /// @notice ERC721 receiver callback to accept NFT transfers
  function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
    return IERC721Receiver.onERC721Received.selector;
  }

  /// @notice ERC1155 receiver callback to accept single token transfers
  function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
    return IERC1155Receiver.onERC1155Received.selector;
  }

  /// @notice ERC1155 receiver callback to accept batch token transfers
  function onERC1155BatchReceived(
    address,
    address,
    uint256[] calldata,
    uint256[] calldata,
    bytes calldata
  ) external pure returns (bytes4) {
    return IERC1155Receiver.onERC1155BatchReceived.selector;
  }

  /// @notice ERC165 interface support
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721Receiver).interfaceId
      || interfaceId == type(IERC1155Receiver).interfaceId;
  }

  /// @inheritdoc IOmnibus
  function setVerifierActivity(address verifier, bool active) external onlyOwner {
    if (verifier == address(0)) revert ZeroVerifier();
    verifierActive[verifier] = active;
    emit VerifierActivityUpdated(verifier, active);
  }

  /// @inheritdoc IOmnibus
  function setCommitmentFee(uint256 newFee) external onlyOwner {
    if (newFee > MAX_FEE) revert FeeExceedsMax();
    uint256 oldFee = commitmentFee;
    commitmentFee = newFee;
    emit FeeUpdated(oldFee, newFee);
  }

  /// @inheritdoc IOmnibus
  function withdrawFees(address to) external onlyOwner {
    if (to == address(0)) revert ZeroFeeRecipient();
    // only accrued fees are withdrawable; escrowed native stays owed to reclaimRecipients
    uint256 amount = accruedFees;
    delete accruedFees;
    SafeTransferLib.safeTransferETH(to, amount);
    emit FeesWithdrawn(to, amount);
  }

  /// @notice the ONE digest code path — commit and the public commitDigest view both call this
  /// @dev raw tagged keccak (no EIP-712): every honest signer in this stack signs raw
  /// 32-byte digests. Binds the FULL context: which swap instance (lock), which side is
  /// being posted (partyTerms), the whole negotiated pairing (counterpartyTerms), the
  /// declared identity (signerHash), and the replay scope (DOMAIN_SEPARATOR —
  /// binds tag + chainid + address(this); do NOT remove; bind less and
  /// signatures become liftable)
  /// @param lock the hashlock identifier
  /// @param partyTerms the committing side's terms digest
  /// @param counterpartyTerms the other side's terms digest
  /// @param signerHash keccak256 of the committing side's identity blob
  /// @return digest the 32-byte commit digest
  function _commitDigest(
    bytes32 lock,
    bytes32 partyTerms,
    bytes32 counterpartyTerms,
    bytes32 signerHash
  ) internal view returns (bytes32) {
    return keccak256(abi.encode(DOMAIN_SEPARATOR, lock, partyTerms, counterpartyTerms, signerHash));
  }

  /// @notice enforces the commit is authorized by the declared identity or by
  /// quip-wallet membership
  /// @dev view-only; resolves to STATICCALLs — no reentrancy surface. There is no
  /// identity membership check: identities attribute, they don't gate; the declared
  /// blob is bound into the digest (signerHash ingredient). The ONLY accepted
  /// identity shape is ERC-7913 keyed: verifier(20 bytes) ‖ key. Anything 20 bytes
  /// or shorter (including a bare address) is MalformedSigner. Two routes past
  /// that shared shape gate:
  /// - non-empty signature (KEYED): the declared verifier must be
  ///   owner-activated and verify(key, digest, sig) must return its selector
  /// - empty signature (WALLET): msg.sender must be a wallet deployed by the
  ///   quip WalletFactory (vaultIdOf is write-once, non-zero iff
  ///   factory-deployed). The digest is not re-verified here: a vetted wallet
  ///   only reaches commit from its PQ-authenticated execute flow. The signer
  ///   blob is shape-checked attribution only on this route — its verifier
  ///   prefix is neither activity-checked nor consulted
  /// @param auth the committing side's identity blob and signature (empty
  /// selects the wallet route)
  /// @param digest the commit digest the identity must have endorsed (keyed
  /// route only)
  function _enforceCommitAuthorized(CommitAuth calldata auth, bytes32 digest) internal view {
    bytes calldata signer = auth.signer;
    if (signer.length <= 20) revert MalformedSigner();

    if (auth.signature.length == 0) {
      if (WALLET_FACTORY.vaultIdOf(msg.sender) == bytes32(0)) revert NotQuipWallet();
      return;
    }

    // ERC-7913 keyed: verifier(20) ‖ key
    address verifier = address(bytes20(signer[:20]));
    if (!verifierActive[verifier]) revert VerifierNotActive();
    if (
      IERC7913SignatureVerifier(verifier).verify(signer[20:], digest, auth.signature)
        != IERC7913SignatureVerifier.verify.selector
    ) revert InvalidCommitSignature();
  }

  /// @notice advances lock state to target with transition validation
  /// @dev valid transitions: unused->free, unused->committed, free->committed, free->spent, committed->spent
  /// @param lock the hashlock identifier
  /// @param current the current lock state (passed to avoid storage read)
  /// @param to the target lock state
  function _advanceLockTo(bytes32 lock, LockState current, LockState to) internal {
    bool advanceUnused = current == LockState.Unused && (to == LockState.Free || to == LockState.Committed);
    bool advanceFree = current == LockState.Free && (to == LockState.Committed || to == LockState.Spent);
    bool advanceCommitted = current == LockState.Committed && to == LockState.Spent;

    if (!advanceUnused && !advanceFree && !advanceCommitted) revert InvalidLockAdvancement();

    lockState[lock] = to;
  }

  /// @notice reverts if expected and actual terms hashes do not match
  /// @param expected the expected terms hash
  /// @param actual the actual terms hash
  function _enforceSameTerms(bytes32 expected, bytes32 actual) internal pure {
    if (expected != actual) revert TermsMismatch();
  }

  /// @notice reverts if native amount received does not match expected
  /// @param expected the expected native amount
  function _enforceCorrectNative(uint256 expected) internal view {
    if (msg.value != expected) revert IncorrectNativeAmountReceived();
  }

  /// @notice reverts if lock state is not committed
  /// @param current the current lock state
  function _enforceCommittedLock(LockState current) internal pure {
    if (current != LockState.Committed) revert InvalidLockState();
  }

  /// @notice reverts if a side was not posted for the lock
  /// @param lock the hashlock identifier
  /// @param termsDigest the side's terms digest
  function _enforcePosted(bytes32 lock, bytes32 termsDigest) internal view {
    if (!posted[lock][termsDigest]) revert TermsNotPosted();
  }

  /// @notice generates a lock from a secret
  /// @param secret the preimage
  /// @return lock the hash of the secret
  function _generateLock(bytes32 secret) internal pure returns (bytes32 lock) {
    lock = EfficientHashLib.hash(secret);
  }

  function _swapId(bytes32 lock, bytes32 canonicalDigest) internal pure returns (bytes32 swapId) {
    swapId = EfficientHashLib.hash(lock, canonicalDigest);
  }

}
