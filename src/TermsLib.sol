// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IERC1155} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155.sol';
import {IERC721} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

/// @notice the type of asset
enum AssetType {
  Native,
  ERC20,
  ERC721,
  ERC1155
}

/// @notice an asset to be transferred as part of a quip
struct Asset {
  /// @notice the type of asset
  AssetType assetType;
  /// @notice the contract address of the asset, zero for native
  address target;
  /// @notice the token id, only used for erc721 and erc1155
  uint256 id;
  /// @notice the amount, only used for native, erc20, and erc1155
  uint256 amount;
}

/// @notice the terms for a single party in a quip proposal
struct PartyTerms {
  /// @notice the address of the party (signer)
  address signatory;
  /// @notice the address that receives the counterparty's assets
  address recipient;
  /// @notice the deadline for the party to commit
  uint64 expiry;
  /// @notice the assets offered by the party
  Asset[] assets;
}

/// @notice the terms of a quip agreement
struct QuipTerms {
  /// @notice the address that creates the quip
  address party;
  /// @notice the address that receives the counterparty's assets
  address partyRecipient;
  /// @notice the address that accepts the quip
  address counterparty;
  /// @notice the address that receives the party's assets
  address counterpartyRecipient;
  /// @notice the deadline for the party to commit
  uint64 partyExpiry;
  /// @notice the deadline for the counterparty to accept
  uint64 counterpartyExpiry;
  /// @notice the assets offered by the party
  Asset[] partyAssets;
  /// @notice the assets offered by the counterparty
  Asset[] counterpartyAssets;
}

/// @notice the lock state for Omnibus swaps
enum LockState {
  /// @notice default - lock has never been used
  Unused,
  /// @notice same-chain only: one party has committed, waiting for counterparty
  Free,
  /// @notice ready for execute (same-chain: both committed; cross-chain: single commit)
  Committed,
  /// @notice terminal (executed, slashed, or reclaimed)
  Spent
}

/// @notice the terms for a single party in an Omnibus swap
struct TermsV0 {
  /// @notice the chain where these terms are valid
  uint256 chainId;
  /// @notice the address of the party (commits assets)
  address signatory;
  /// @notice the address that receives the counterparty's assets
  address recipient;
  /// @notice the deadline: before can reclaim, after can be slashed
  uint64 deadline;
  /// @notice the collateral levied on slash
  Asset collateral;
  /// @notice the assets offered by the party
  Asset[] assets;
}

library TermsLib {
  /// @notice thrown when an asset has zero amount
  error ZeroAmount();

  /// @notice thrown when chainId does not match current chain
  error InvalidChainId();

  /// @notice thrown when a native asset has invalid fields
  error InvalidNativeAsset();

  /// @notice thrown when an erc20 asset has invalid fields
  error InvalidERC20Asset();

  /// @notice thrown when an erc721 asset has invalid fields
  error InvalidERC721Asset();

  /// @notice thrown when an erc1155 asset has invalid fields
  error InvalidERC1155Asset();

  /// @notice thrown when provided terms do not match the stored digest
  error InvalidTerms();

  /// @notice thrown when the terms have expired
  error TermsExpired();

  /// @notice thrown when the terms have not yet expired
  error TermsNotExpired();

  /// @notice computes the keccak256 digest of party terms
  /// @param terms the party terms to hash
  /// @return digest the keccak256 hash of the encoded terms
  function digestPartyTerms(PartyTerms calldata terms) internal pure returns (bytes32 digest) {
    digest = keccak256(abi.encode(terms.signatory, terms.recipient, terms.expiry, terms.assets));
  }

  /// @notice combines two party terms into a full quip terms struct
  /// @param party the initiating party's terms
  /// @param counterparty the counterparty's terms
  /// @return coupled the combined quip terms
  function coupleTerms(
    PartyTerms calldata party,
    PartyTerms calldata counterparty
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

  /// @notice computes a canonical digest of quip terms regardless of party/counterparty order
  /// @dev Used for WOTS+ signing - same signature works on both sides of a swap
  /// @param terms the quip terms to hash
  /// @return canonicalDigest the canonical hash (smaller digest first)
  function digestTermsCanonically(QuipTerms calldata terms) internal pure returns (bytes32 canonicalDigest) {
    bytes32 partyDigest = EfficientHashLib.hash(
      abi.encode(terms.party, terms.partyRecipient, terms.partyExpiry, terms.partyAssets)
    );
    bytes32 counterpartyDigest = EfficientHashLib.hash(
      abi.encode(terms.counterparty, terms.counterpartyRecipient, terms.counterpartyExpiry, terms.counterpartyAssets)
    );
    // canonical ordering: smaller digest first
    if (uint256(partyDigest) < uint256(counterpartyDigest)) {
      canonicalDigest = EfficientHashLib.hash(partyDigest, counterpartyDigest);
    } else {
      canonicalDigest = EfficientHashLib.hash(counterpartyDigest, partyDigest);
    }
  }

  /// @notice computes a canonical digest of quip terms from memory
  /// @dev Memory variant for use after coupling terms
  /// @param terms the quip terms to hash
  /// @return canonicalDigest the canonical hash (smaller digest first)
  function digestTermsCanonicallyMemory(QuipTerms memory terms) internal pure returns (bytes32 canonicalDigest) {
    bytes32 partyDigest = EfficientHashLib.hash(
      abi.encode(terms.party, terms.partyRecipient, terms.partyExpiry, terms.partyAssets)
    );
    bytes32 counterpartyDigest = EfficientHashLib.hash(
      abi.encode(terms.counterparty, terms.counterpartyRecipient, terms.counterpartyExpiry, terms.counterpartyAssets)
    );
    // canonical ordering: smaller digest first
    if (uint256(partyDigest) < uint256(counterpartyDigest)) {
      canonicalDigest = EfficientHashLib.hash(partyDigest, counterpartyDigest);
    } else {
      canonicalDigest = EfficientHashLib.hash(counterpartyDigest, partyDigest);
    }
  }

  /// @notice reverts if the provided terms do not match the stored canonical digest
  /// @param termsDigest the stored canonical digest to verify against
  /// @param terms the terms to verify
  function verifyTerms(bytes32 termsDigest, QuipTerms calldata terms) internal pure {
    if (digestTermsCanonically(terms) != termsDigest) {
      revert InvalidTerms();
    }
  }

  /// @notice computes a canonical digest of TermsV0 regardless of party/counterparty order
  /// @dev Used for Omnibus hashlock swaps - same hash regardless of which party is passed first
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  /// @return canonicalDigest the canonical hash (smaller digest first)
  function digestTermsV0Canonically(
    TermsV0 calldata party,
    TermsV0 calldata counterparty
  ) internal pure returns (bytes32 canonicalDigest) {
    bytes32 partyDigest = EfficientHashLib.hash(
      abi.encode(party.chainId, party.signatory, party.recipient, party.deadline, party.collateral, party.assets)
    );
    bytes32 counterpartyDigest = EfficientHashLib.hash(
      abi.encode(counterparty.chainId, counterparty.signatory, counterparty.recipient, counterparty.deadline, counterparty.collateral, counterparty.assets)
    );
    // canonical ordering: smaller digest first
    if (uint256(partyDigest) < uint256(counterpartyDigest)) {
      canonicalDigest = EfficientHashLib.hash(partyDigest, counterpartyDigest);
    } else {
      canonicalDigest = EfficientHashLib.hash(counterpartyDigest, partyDigest);
    }
  }

  /// @notice transfers party assets from the quip to the counterparty recipient
  /// @param quip the quip contract holding the assets
  /// @param counterpartyRecipient the address to receive the assets
  /// @param partyAssets the assets to transfer
  function executePartyCommitment(address quip, address counterpartyRecipient, Asset[] calldata partyAssets) internal {
    transferAssets(partyAssets, quip, counterpartyRecipient);
  }

  /// @notice releases party assets back to the party recipient
  /// @param quip the quip contract holding the assets
  /// @param partyRecipient the address to receive the assets
  /// @param partyAssets the assets to transfer
  function releasePartyCommitment(address quip, address partyRecipient, Asset[] calldata partyAssets) internal {
    transferAssets(partyAssets, quip, partyRecipient);
  }

  /// @notice validates that an asset's fields are consistent with its type
  /// @param asset the asset to validate
  function validateAsset(Asset memory asset) internal pure {
    if (asset.amount == 0) {
      revert ZeroAmount();
    }

    bool isNative = asset.assetType == AssetType.Native;
    bool isERC20 = asset.assetType == AssetType.ERC20;
    bool isERC721 = asset.assetType == AssetType.ERC721;
    bool isERC1155 = asset.assetType == AssetType.ERC1155;
    bool isZeroId = asset.id == 0;
    bool isZeroTarget = asset.target == address(0);

    if (isNative && (!isZeroTarget || !isZeroId)) {
      revert InvalidNativeAsset();
    }

    if (isERC20 && (isZeroTarget || !isZeroId)) {
      revert InvalidERC20Asset();
    }

    if (isERC721 && (isZeroTarget || isZeroId)) {
      revert InvalidERC721Asset();
    }

    if (isERC1155 && (isZeroTarget || isZeroId)) {
      revert InvalidERC1155Asset();
    }
  }

  /// @notice transfers a single asset from one address to another
  /// @param asset the asset to transfer
  /// @param from the address to transfer from (ignored for native)
  /// @param to the address to transfer to
  function transferAsset(Asset memory asset, address from, address to) internal {
    if (asset.assetType == AssetType.Native) {
      return SafeTransferLib.safeTransferETH(to, asset.amount);
    }

    if (asset.assetType == AssetType.ERC20) {
      return from == address(this)
        ? SafeTransferLib.safeTransfer(asset.target, to, asset.amount)
        : SafeTransferLib.safeTransferFrom(asset.target, from, to, asset.amount);
    }

    if (asset.assetType == AssetType.ERC721) {
      return IERC721(asset.target).safeTransferFrom(from, to, asset.id);
    }

    IERC1155(asset.target).safeTransferFrom(from, to, asset.id, asset.amount, '');
  }

  /// @notice transfers an array of assets from one address to another
  /// @param assets the assets to transfer
  /// @param from the address to transfer from (ignored for native assets)
  /// @param to the address to transfer to
  function transferAssets(Asset[] memory assets, address from, address to) internal {
    uint256 length = assets.length;
    for (uint256 i; i < length; ++i) {
      transferAsset(assets[i], from, to);
    }
  }

  /// @notice transfers an array of assets excluding native assets
  /// @param assets the assets to transfer
  /// @param from the address to transfer from
  /// @param to the address to transfer to
  function transferAssetsNoNative(Asset[] memory assets, address from, address to) internal {
    uint256 length = assets.length;
    for (uint256 i; i < length; ++i) {
      if (assets[i].assetType != AssetType.Native) {
        transferAsset(assets[i], from, to);
      }
    }
  }

  /// @notice calculates the total native amount in an array of assets
  /// @param assets the assets to sum
  /// @return total the total native amount
  function totalNativeAmount(Asset[] memory assets) internal pure returns (uint256 total) {
    uint256 length = assets.length;
    for (uint256 i; i < length; ++i) {
      if (assets[i].assetType == AssetType.Native) total += assets[i].amount;
    }
  }

  /// @notice reverts if the expiry timestamp has passed
  /// @param expiry the expiry timestamp to check
  function enforceTermFreshness(uint64 expiry) internal view {
    if (block.timestamp >= expiry) {
      revert TermsExpired();
    }
  }

  /// @notice reverts if the expiry timestamp has not passed
  /// @param expiry the expiry timestamp to check
  function enforceTermStaleness(uint64 expiry) internal view {
    if (block.timestamp < expiry) {
      revert TermsNotExpired();
    }
  }

  /// @notice validates both party and counterparty terms for commit
  /// @dev only party.chainId must match current chain; counterparty.chainId may differ for cross-chain
  /// @param party the committing party's terms (must be on current chain)
  /// @param counterparty the counterparty's terms (validated but chainId not enforced)
  function validateTermsV0(TermsV0 calldata party, TermsV0 calldata counterparty) internal view {
    // party.chainId must match current chain
    if (party.chainId != block.chainid) revert InvalidChainId();

    // validate party terms
    enforceTermFreshness(party.deadline);
    _validateTermsAssets(party);

    // validate counterparty terms (but not chainId)
    enforceTermFreshness(counterparty.deadline);
    _validateTermsAssets(counterparty);
  }

  /// @notice validates collateral and assets in terms
  /// @param terms the terms to validate
  function _validateTermsAssets(TermsV0 calldata terms) private pure {
    validateAsset(terms.collateral);
    uint256 length = terms.assets.length;
    for (uint256 i; i < length; ++i) {
      validateAsset(terms.assets[i]);
    }
  }

  /// @notice transfers non-native assets (collateral + assets) into the contract
  /// @param terms the party's terms containing assets to transfer
  /// @param from the address to transfer from
  /// @param to the address to transfer to
  function transferNonNativeAssetsIn(TermsV0 calldata terms, address from, address to) internal {
    // transfer collateral if non-native
    if (terms.collateral.assetType != AssetType.Native) {
      transferAsset(terms.collateral, from, to);
    }

    // transfer all non-native assets
    transferAssetsNoNative(terms.assets, from, to);
  }

  /// @notice calculates total native amount from TermsV0 (collateral + assets)
  /// @param terms the party's terms
  /// @return total the total native amount required
  function totalNativeAmountV0(TermsV0 calldata terms) internal pure returns (uint256 total) {
    // add collateral if native
    if (terms.collateral.assetType == AssetType.Native) {
      total = terms.collateral.amount;
    }

    // add native assets
    total += totalNativeAmount(terms.assets);
  }

  /// @notice generates a lock from a secret
  /// @param secret the preimage
  /// @return lock the hash of the secret
  function generateLock(bytes32 secret) internal pure returns (bytes32 lock) {
    lock = EfficientHashLib.hash(secret);
  }
}
