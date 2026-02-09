// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PartyTerms, QuipTerms, TermsLib} from './TermsLib.sol';
import {IQuip} from './interfaces/IQuip.sol';
import {Context} from '@openzeppelin-contracts-5.6.0-rc.1/utils/Context.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';
import {Initializable} from 'solady-0.1.26/utils/Initializable.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';

//TODO:
// - Slashing
// - Winternitz security (?)
// - QuipPortal (onlyPortal) modifier on initializer
contract Quip is Context, Initializable, IQuip {
  /// @notice the version of this quip implementation
  uint256 public constant VERSION = 1;

  /// @notice hash of the secret key used to authorize asset claiming
  bytes32 public lock;

  /// @notice hash of terms connected to this Quip
  /// @dev Lifecycle depends on initialization mode:
  ///      - Uncoupled: starts as h(PartyTerms), updates to h(QuipTerms) after coupling
  ///      - Coupled: starts as h(QuipTerms)
  bytes32 public termsDigest;

  /// @notice true if initialized in uncoupled mode, allowing one termsDigest update
  /// forge-lint: disable-next-line
  bool public INIT_UNCOUPLED;


  /// @notice returns the factory that deployed this quip, stored as an immutable clone argument
  function FACTORY() public view returns (address) {
    return abi.decode(LibClone.argsOnClone(address(this), 0, 32), (address));
  }

  /// TODO:
  /// - means this address is coupled to _termsDigest
  /// - means _termDigest = h(`QuipTerm`) (full struct information indicative of intent)
  /// @notice initializes the quip with a lock and terms
  /// @param _lock the hash of the secret
  /// @param _termsDigest the hashed terms of the quip agreement
  function initializeCoupled(bytes32 _lock, bytes32 _termsDigest) external initializer {
    lock = _lock;
    termsDigest = _termsDigest;
    //  INIT_UNCOUPLED default initialize to false

    emit PartyCommitment(_termsDigest);
  }

  /// @notice initializes the quip in uncoupled mode for proposal-based swaps
  /// @dev No assets are transferred; only stores party terms digest which can be updated once via coupleQuip
  /// @param _lock the hash of the secret key
  /// @param _termsDigest the hash of PartyTerms (not full QuipTerms)
  function initializeUncoupled(bytes32 _lock, bytes32 _termsDigest) external initializer {
    lock = _lock;
    termsDigest = _termsDigest;
    INIT_UNCOUPLED = true;

    emit PartyProposal(_lock, _termsDigest);
  }

  /// @notice couples an uncoupled quip by committing assets and updating terms digest
  /// @dev Only callable by the original party; transitions termsDigest from h(PartyTerms) to h(QuipTerms)
  /// @param party the initiating party's terms (must match stored digest)
  /// @param counterparty the counterparty's terms to couple with
  /// @param _termsDigest the stored digest to verify against party terms
  function coupleQuip(
    PartyTerms calldata party,
    PartyTerms calldata counterparty,
    bytes32 _termsDigest
  ) external payable {
    // cannot couple unless initialized uncoupled
    if (!INIT_UNCOUPLED) revert InvalidOperation();
    // cannot update _termsDigest unless the initial terms that match the digest are used
    if (_termsDigest != TermsLib.digestPartyTerms(party)) revert InvalidOperation();
    if (_msgSender() != party.signatory) revert UnauthorizedCaller();
    QuipTerms memory coupledTerms = TermsLib.coupleTerms(party, counterparty);
    if (msg.value != TermsLib.totalNativeAmount(party.assets)) revert InsufficientCommitment();

    termsDigest = TermsLib.digestTermsMemory(coupledTerms);
    TermsLib.transferAssetsNoNative(party.assets, party.signatory, address(this));

    emit QuipCommitted(_termsDigest);
  }

  /// @notice claims the party's assets by providing the key and terms
  /// @dev Permissionless by design - possession of valid key proves authorization
  /// @param key the secret that unlocks the quip
  /// @param terms the terms of the quip agreement
  function claim(bytes calldata key, QuipTerms calldata terms) external {
    _verifyKey(key);
    TermsLib.verifyTerms(termsDigest, terms);
    TermsLib.enforceTermFreshness(terms.partyExpiry);
    TermsLib.executePartyCommitment(address(this), terms.counterpartyRecipient, terms.partyAssets);

    emit PartyTermsFulfilled(key, terms.counterpartyRecipient, terms.partyAssets);
  }

  /// @notice reclaims the party's assets after the terms have expired
  /// @dev Permissionless by design - anyone can trigger reclaim after expiry
  /// @param terms the terms of the quip agreement
  function reclaim(QuipTerms calldata terms) external {
    TermsLib.verifyTerms(termsDigest, terms);
    TermsLib.enforceTermStaleness(terms.partyExpiry);
    TermsLib.releasePartyCommitment(address(this), terms.partyRecipient, terms.partyAssets);

    emit PartyUnbound(terms.partyRecipient, terms.partyAssets);
  }

  /// @notice reverts if the provided key does not match the lock
  /// @param key the key to verify
  function _verifyKey(bytes calldata key) internal view {
    if (EfficientHashLib.hash(key) != lock) {
      revert InvalidKey();
    }
  }
}
