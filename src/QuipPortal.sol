// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PartyTerms, QuipTerms, TermsLib} from './TermsLib.sol';
import {IQuip} from './interfaces/IQuip.sol';
import {IQuipPortal, PqOwnerState} from './interfaces/IQuipPortal.sol';
import {Context} from '@openzeppelin-contracts-5.6.0-rc.1/utils/Context.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

contract QuipPortal is Context, IQuipPortal {
  /// @notice the factory version
  uint256 public constant VERSION = 1;

  /// @notice maximum fee that can ever be set
  uint256 public immutable MAX_FEE;

  /// @notice current fee charged for quip creation
  uint256 public creationFee;

  /// @notice total fees available for withdrawal
  uint256 public accumulatedFees;

  /// @notice address with admin privileges
  address public admin;

  /// @notice the quip implementation used for cloning
  address immutable QUIP_IMPLEMENTATION;

  /// @notice tracks the lifecycle state of each pqOwner (WOTS+ public key)
  /// @dev See PqOwnerState enum for state transitions
  mapping(bytes32 pqOwnerHash => PqOwnerState state) public pqOwnerState;

  /// @notice the expected codehash of valid quip clones deployed by this portal
  /// @dev Set on first deployment; all clones share the same runtime bytecode
  bytes32 public QUIP_CODEHASH;

  modifier onlyAdmin() {
    _onlyAdmin();
    _;
  }

  /// @notice deploys a new quip portal
  /// @param firstAdmin the initial admin address
  /// @param quipImpl the quip implementation address used for cloning
  /// @param maxFee the maximum creation fee that can ever be set
  /// @param _creationFee the initial creation fee
  constructor(address firstAdmin, address quipImpl, uint256 maxFee, uint256 _creationFee) {
    _enforceNonEmptyAddress(firstAdmin);
    _enforceNonEmptyAddress(quipImpl);
    if (_creationFee > maxFee) revert FeeExceedsMax();
    QUIP_IMPLEMENTATION = quipImpl;
    MAX_FEE = maxFee;
    admin = firstAdmin;
    creationFee = _creationFee;
  }

  /// @notice creates a new quip with the given WOTS+ public key and terms
  /// @dev Salt for deterministic deployment is keccak256(pqOwnerHash, msg.sender) to allow
  ///      same-chain swaps where both parties deploy with the same pqOwner
  /// @param pqOwner the WOTS+ public key used for deterministic deployment
  /// @param terms the terms of the quip agreement
  function deployCoupledQuip(WOTSPlus.WinternitzAddress calldata pqOwner, QuipTerms calldata terms) external payable {
    bytes32 _pqOwnerHash = _computePqOwnerHash(pqOwner);
    _enforceValidPqOwner(pqOwner, _pqOwnerHash);
    _validateQuipTerms(terms);
    _ensureCorrectNative(creationFee + TermsLib.totalNativeAmount(terms.partyAssets));

    _advancePqOwner(_pqOwnerHash);
    address quip = _deployQuip(_pqOwnerHash, _msgSender());
    IQuip(quip).initializeCoupled(pqOwner, TermsLib.digestTermsCanonically(terms));

    accumulatedFees += creationFee;
    TermsLib.transferAssets(terms.partyAssets, _msgSender(), quip);

    emit QuipCreated(_pqOwnerHash, quip, terms);
  }

  /// @notice creates a new quip and immediately claims it in a single transaction
  /// @dev Combines deployCoupledQuip and claim into one atomic operation.
  ///      Useful when the counterparty wants to deploy and claim in one tx.
  /// @param pqOwner the WOTS+ public key used for deterministic deployment
  /// @param signature the WOTS+ signature authorizing the claim
  /// @param terms the terms of the quip agreement
  function deployAndClaimCoupledQuip(WOTSPlus.WinternitzAddress calldata pqOwner, WOTSPlus.WinternitzElements calldata signature, QuipTerms calldata terms) external payable {
    bytes32 _pqOwnerHash = _computePqOwnerHash(pqOwner);
    _enforceValidPqOwner(pqOwner, _pqOwnerHash);
    _validateQuipTerms(terms);
    _ensureCorrectNative(creationFee + TermsLib.totalNativeAmount(terms.partyAssets));

    _advancePqOwner(_pqOwnerHash);
    address quip = _deployQuip(_pqOwnerHash, _msgSender());
    IQuip(quip).initializeCoupled(pqOwner, TermsLib.digestTermsCanonically(terms));

    accumulatedFees += creationFee;
    TermsLib.transferAssets(terms.partyAssets, _msgSender(), quip);

    IQuip(quip).claim(signature, terms);

    emit QuipCreatedAndClaimed(_pqOwnerHash, quip, terms);
  }

  /// @notice creates a new uncoupled quip proposal with party terms only
  /// @dev Salt for deterministic deployment is keccak256(pqOwnerHash, msg.sender) to allow
  ///      same-chain swaps where both parties deploy with the same pqOwner
  /// @param pqOwner the WOTS+ public key used for deterministic deployment
  /// @param terms the party terms of the quip proposal
  function deployUncoupledQuip(WOTSPlus.WinternitzAddress calldata pqOwner, PartyTerms calldata terms) external payable {
    bytes32 _pqOwnerHash = _computePqOwnerHash(pqOwner);
    _enforceValidPqOwner(pqOwner, _pqOwnerHash);
    _validatePartyTerms(terms);
    // right now only fee needs to be paid; no forwarding here
    _ensureCorrectNative(creationFee);

    _advancePqOwner(_pqOwnerHash);
    address quip = _deployQuip(_pqOwnerHash, _msgSender());
    IQuip(quip).initializeUncoupled(pqOwner, TermsLib.digestPartyTerms(terms));

    accumulatedFees += creationFee;

    emit QuipProposed(_pqOwnerHash, quip, terms);
  }

  /// @notice withdraws accumulated fees to the given receiver
  /// @param receiver the address to receive the fees
  /// @param amount the amount of fees to withdraw
  function withdrawFees(address receiver, uint256 amount) external onlyAdmin {
    if (amount > accumulatedFees) {
      revert InsufficientFees();
    }
    accumulatedFees -= amount;
    SafeTransferLib.safeTransferETH(receiver, amount);

    emit FeesWithdrawn(receiver, amount);
  }

  /// @notice updates the creation fee
  /// @param newFee the new creation fee
  function setCreationFee(uint256 newFee) external onlyAdmin {
    if (newFee > MAX_FEE) revert FeeExceedsMax();
    creationFee = newFee;

    emit CreationFeeUpdated(newFee);
  }

  /// @notice marks a pqOwner as spent, callable only by quip contracts deployed by this portal
  /// @dev Called by Quip.claim() and Quip.reclaim() to transition pqOwner state.
  ///      Idempotent: if already Spent, this is a no-op (supports same-chain swaps
  ///      where both quips may claim/reclaim).
  /// @param _pqOwnerHash the pqOwnerHash to mark as spent
  function spendPqOwner(bytes32 _pqOwnerHash) external {
    // verify caller is a quip clone deployed by this portal
    // the clone stores this portal's address as immutable args in bytecode
    _enforceQuipCaller();

    PqOwnerState currentState = pqOwnerState[_pqOwnerHash];

    // only transition if Free; Spent is terminal and idempotent
    if (currentState == PqOwnerState.Free) {
      pqOwnerState[_pqOwnerHash] = PqOwnerState.Spent;
      emit SpentPqOwner(_pqOwnerHash, _msgSender());
    }
    // if already Spent, no-op (idempotent for same-chain swaps)
    // if Unused, this shouldn't happen (quip shouldn't exist), but we don't revert
  }

  /// @notice deploys a new quip clone using keccak256(pqOwnerHash, deployer) as the salt
  /// @dev Using (pqOwnerHash, deployer) as salt enables same-chain swaps where both parties
  ///      deploy with the same pqOwner but get unique quip addresses.
  ///      On first deployment, captures the clone's codehash for future verification.
  /// @param _pqOwnerHash the pqOwnerHash
  /// @param deployer the address deploying the quip
  /// @return quip the address of the deployed quip
  function _deployQuip(bytes32 _pqOwnerHash, address deployer) internal returns (address quip) {
    bytes32 salt = EfficientHashLib.hash(_pqOwnerHash, bytes32(uint256(uint160(deployer))));
    // factory address is encoded in bytecode, salt uniquifies the deployment address
    quip = LibClone.cloneDeterministic(QUIP_IMPLEMENTATION, abi.encode(address(this)), salt);

    // capture codehash on first deployment for future caller verification
    // all clones have identical runtime bytecode, so one codehash validates all
    if (QUIP_CODEHASH == bytes32(0)) {
      QUIP_CODEHASH = quip.codehash;
    }
  }

  /// @notice reverts if msg.value does not match the expected amount
  /// @param amount the expected native amount
  function _ensureCorrectNative(uint256 amount) internal view {
    if (msg.value != amount) {
      revert IncorrectNativeAmount();
    }
  }

  /// @notice validates that the pqOwner is non-empty and not already spent
  /// @dev Reverts if pqOwner has empty fields or already Spent
  /// @param pqOwner the WinternitzAddress to validate
  /// @param _pqOwnerHash the precomputed hash of the pqOwner
  function _enforceValidPqOwner(
    WOTSPlus.WinternitzAddress calldata pqOwner,
    bytes32 _pqOwnerHash
  ) internal view {
    if (pqOwner.publicSeed == bytes32(0) || pqOwner.publicKeyHash == bytes32(0)) revert EmptyPqOwner();
    if (pqOwnerState[_pqOwnerHash] == PqOwnerState.Spent) revert PqOwnerSpent();
  }

  /// @notice advances the pqOwner state: Unused → Free → Spent
  /// @dev Must be called after _enforceValidPqOwner
  /// @param _pqOwnerHash the pqOwnerHash to advance
  function _advancePqOwner(bytes32 _pqOwnerHash) internal {
    PqOwnerState currentState = pqOwnerState[_pqOwnerHash];
    pqOwnerState[_pqOwnerHash] = currentState == PqOwnerState.Unused ? PqOwnerState.Free : PqOwnerState.Spent;
  }

  /// @notice computes the hash of a WinternitzAddress
  /// @param pqOwner the WOTS+ public key
  /// @return the hash of the public key
  function _computePqOwnerHash(WOTSPlus.WinternitzAddress calldata pqOwner) internal pure returns (bytes32) {
    return EfficientHashLib.hash(pqOwner.publicSeed, pqOwner.publicKeyHash);
  }

  /// @notice reverts if the address is the zero address
  /// @param addr the address to validate
  function _enforceNonEmptyAddress(address addr) internal pure {
    if (addr == address(0)) revert EmptyAddress();
  }

  /// @notice validates the quip terms provided during creation
  /// @param terms the terms to validate
  function _validateQuipTerms(QuipTerms calldata terms) internal view {
    if (terms.party == address(0) || terms.counterparty == address(0)) revert EmptyParty();
    if (terms.partyRecipient == address(0) || terms.counterpartyRecipient == address(0)) revert EmptyRecipient();
    if (terms.partyExpiry <= block.timestamp || terms.counterpartyExpiry <= block.timestamp) revert InvalidExpiry();
    if (terms.partyAssets.length == 0 || terms.counterpartyAssets.length == 0) revert EmptyAssets();

    uint256 partyAssetsLength = terms.partyAssets.length;
    for (uint256 i; i < partyAssetsLength; ++i) {
      TermsLib.validateAsset(terms.partyAssets[i]);
    }

    uint256 counterpartyAssetsLength = terms.counterpartyAssets.length;
    for (uint256 i; i < counterpartyAssetsLength; ++i) {
      TermsLib.validateAsset(terms.counterpartyAssets[i]);
    }
  }

  /// @notice reverts if the caller is not the admin
  function _onlyAdmin() internal view {
    if (_msgSender() != admin) {
      revert NotAdmin();
    }
  }

  /// @notice reverts if the caller is not a quip clone deployed by this portal
  /// @dev Verifies caller's codehash matches the expected codehash of valid quip clones.
  ///      All clones from this portal have identical runtime bytecode (same implementation
  ///      + same immutable args), so they share the same codehash.
  function _enforceQuipCaller() internal view {
    if (_msgSender().codehash != QUIP_CODEHASH) revert CallerNotQuip();
  }

  /// @notice validates the party terms provided during uncoupled quip creation
  /// @param terms the party terms to validate
  function _validatePartyTerms(PartyTerms calldata terms) internal view {
    if (terms.signatory == address(0)) revert EmptyParty();
    if (terms.recipient == address(0)) revert EmptyRecipient();
    if (terms.expiry <= block.timestamp) revert InvalidExpiry();
    if (terms.assets.length == 0) revert EmptyAssets();

    uint256 assetsLength = terms.assets.length;
    for (uint256 i; i < assetsLength; ++i) {
      TermsLib.validateAsset(terms.assets[i]);
    }
  }
}
