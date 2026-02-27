// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PartyTerms, QuipTerms, TermsLib} from './TermsLib.sol';
import {IQuip} from './interfaces/IQuip.sol';
import {IQuipPortal} from './interfaces/IQuipPortal.sol';
import {IERC1155Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155Receiver.sol';
import {IERC721Receiver} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721Receiver.sol';
import {Context} from '@openzeppelin-contracts-5.6.0-rc.1/utils/Context.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';
import {Initializable} from 'solady-0.1.26/utils/Initializable.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

//TODO:
// - Slashing
contract Quip is Context, Initializable, IQuip, IERC721Receiver, IERC1155Receiver {
  /// @notice the version of this quip implementation
  uint256 public constant VERSION = 1;

  /// @notice WOTS+ public key that authorizes asset claiming
  WOTSPlus.WinternitzAddress public pqOwner;

  /// @notice canonical hash of terms connected to this Quip
  /// @dev Lifecycle depends on initialization mode:
  ///      - Uncoupled: starts as h(PartyTerms), updates to canonical(QuipTerms) after coupling
  ///      - Coupled: starts as canonical(QuipTerms)
  bytes32 public termsDigest;

  /// @notice true if initialized in uncoupled mode, allowing one termsDigest update
  /// forge-lint: disable-next-line
  bool public INIT_UNCOUPLED;

  /// @notice ensures caller is the valid portal
  modifier onlyPortal() {
    _onlyPortal();
    _;
  }

  /// @notice allows this contract to receive native currency
  receive() external payable {}

  /// @notice returns the portal that deployed this quip, stored as an immutable clone argument in the bytecode
  /// forge-lint: disable-next-line
  function PORTAL_FROM_BYTECODE() public view returns (address) {
    return abi.decode(LibClone.argsOnClone(address(this), 0, 32), (address));
  }

  /// @notice returns the hash of the WOTS+ public key
  /// @return the EfficientHashLib hash of (publicSeed, publicKeyHash)
  function pqOwnerHash() public view returns (bytes32) {
    return EfficientHashLib.hash(pqOwner.publicSeed, pqOwner.publicKeyHash);
  }

  /// @notice initializes the quip with a WOTS+ public key and terms
  /// @param _pqOwner the WOTS+ public key
  /// @param _termsDigest the canonical hashed terms of the quip agreement
  function initializeCoupled(
    WOTSPlus.WinternitzAddress calldata _pqOwner,
    bytes32 _termsDigest
  ) external onlyPortal initializer {
    pqOwner = _pqOwner;
    termsDigest = _termsDigest;
    //  INIT_UNCOUPLED default initialize to false

    emit PartyCommitment(EfficientHashLib.hash(_pqOwner.publicSeed, _pqOwner.publicKeyHash), _termsDigest);
  }

  /// @notice initializes the quip in uncoupled mode for proposal-based swaps
  /// @dev No assets are transferred; only stores party terms digest which can be updated once via coupleQuip
  /// @param _pqOwner the WOTS+ public key
  /// @param _termsDigest the hash of PartyTerms (not full QuipTerms)
  function initializeUncoupled(
    WOTSPlus.WinternitzAddress calldata _pqOwner,
    bytes32 _termsDigest
  ) external onlyPortal initializer {
    pqOwner = _pqOwner;
    termsDigest = _termsDigest;
    INIT_UNCOUPLED = true;

    emit PartyProposal(EfficientHashLib.hash(_pqOwner.publicSeed, _pqOwner.publicKeyHash), _termsDigest);
  }

  /// @notice couples an uncoupled quip by committing assets and updating terms digest
  /// @dev Only callable by the original party; transitions termsDigest from h(PartyTerms) to canonical(QuipTerms)
  /// @param party the initiating party's terms (must match stored digest)
  /// @param counterparty the counterparty's terms to couple with
  function coupleQuip(PartyTerms calldata party, PartyTerms calldata counterparty) external payable {
    // cannot couple unless initialized uncoupled
    if (!INIT_UNCOUPLED) revert InvalidOperation();
    // cannot update termsDigest unless the initial terms that match the digest are used
    if (termsDigest != TermsLib.digestPartyTerms(party)) revert InvalidOperation();
    if (_msgSender() != party.signatory) revert UnauthorizedCaller();
    QuipTerms memory coupledTerms = TermsLib.coupleTerms(party, counterparty);
    if (msg.value != TermsLib.totalNativeAmount(party.assets)) revert InsufficientCommitment();

    termsDigest = TermsLib.digestTermsCanonicallyMemory(coupledTerms);
    TermsLib.transferAssetsNoNative(party.assets, party.signatory, address(this));

    emit QuipCommitted(termsDigest);
  }

  /// @notice claims the party's assets by providing a WOTS+ signature and terms
  /// @dev Permissionless by design - possession of valid signature proves authorization.
  ///      Marks the pqOwner as spent on the portal to prevent further deployments.
  /// @param signature the WOTS+ signature authorizing the claim
  /// @param terms the terms of the quip agreement
  function claim(WOTSPlus.WinternitzElements calldata signature, QuipTerms calldata terms) external {
    TermsLib.verifyTerms(termsDigest, terms);
    _verifySignature(signature);
    TermsLib.enforceTermFreshness(terms.partyExpiry);

    // mark pqOwner as spent on portal (idempotent for same-chain swaps)
    IQuipPortal(PORTAL_FROM_BYTECODE()).spendPqOwner(pqOwnerHash());

    TermsLib.executePartyCommitment(address(this), terms.counterpartyRecipient, terms.partyAssets);

    emit PartyTermsFulfilled(signature, terms.counterpartyRecipient, terms.partyAssets);
  }

  /// @notice reclaims the party's assets after the terms have expired
  /// @dev Permissionless by design - anyone can trigger reclaim after expiry.
  ///      Marks the pqOwner as spent on the portal to prevent further deployments.
  /// @param terms the terms of the quip agreement
  function reclaim(QuipTerms calldata terms) external {
    TermsLib.verifyTerms(termsDigest, terms);
    TermsLib.enforceTermStaleness(terms.partyExpiry);

    // mark pqOwner as spent on portal (idempotent for same-chain swaps)
    IQuipPortal(PORTAL_FROM_BYTECODE()).spendPqOwner(pqOwnerHash());

    TermsLib.releasePartyCommitment(address(this), terms.partyRecipient, terms.partyAssets);

    emit PartyUnbound(terms.partyRecipient, terms.partyAssets);
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
    return interfaceId == type(IERC721Receiver).interfaceId || interfaceId == type(IERC1155Receiver).interfaceId;
  }

  /// @notice verifies the WOTS+ signature over the stored terms digest
  /// @param signature the WOTS+ signature to verify
  function _verifySignature(WOTSPlus.WinternitzElements calldata signature) internal view {
    WOTSPlus.WinternitzMessage memory message = WOTSPlus.WinternitzMessage({messageHash: termsDigest});
    if (!WOTSPlus.verify(pqOwner, message, signature)) {
      revert InvalidSignature();
    }
  }

  /// @notice reverts if caller is not the portal that deployed this quip
  function _onlyPortal() internal view {
    if (_msgSender() != PORTAL_FROM_BYTECODE()) revert CallerNotPortal();
  }
}
