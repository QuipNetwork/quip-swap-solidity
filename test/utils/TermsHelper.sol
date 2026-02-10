// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, PartyTerms, QuipTerms} from '../../src/TermsLib.sol';

/// @title Terms Helper
/// @dev Utility functions for building Terms structs in tests
library TermsHelper {
  /// @notice Creates PartyTerms struct
  /// @param signatory The party's address
  /// @param recipient The recipient's address
  /// @param expiry The expiry timestamp
  /// @param assets The assets array
  /// @return terms The constructed PartyTerms struct
  function makePartyTerms(
    address signatory,
    address recipient,
    uint64 expiry,
    Asset[] memory assets
  ) internal pure returns (PartyTerms memory terms) {
    terms = PartyTerms({signatory: signatory, recipient: recipient, expiry: expiry, assets: assets});
  }

  /// @notice Creates QuipTerms struct
  /// @param party The party's address
  /// @param partyRecipient The party's recipient address
  /// @param counterparty The counterparty's address
  /// @param counterpartyRecipient The counterparty's recipient address
  /// @param partyExpiry The party's expiry timestamp
  /// @param counterpartyExpiry The counterparty's expiry timestamp
  /// @param partyAssets The party's assets array
  /// @param counterpartyAssets The counterparty's assets array
  /// @return terms The constructed QuipTerms struct
  function makeQuipTerms(
    address party,
    address partyRecipient,
    address counterparty,
    address counterpartyRecipient,
    uint64 partyExpiry,
    uint64 counterpartyExpiry,
    Asset[] memory partyAssets,
    Asset[] memory counterpartyAssets
  ) internal pure returns (QuipTerms memory terms) {
    terms = QuipTerms({
      party: party,
      partyRecipient: partyRecipient,
      counterparty: counterparty,
      counterpartyRecipient: counterpartyRecipient,
      partyExpiry: partyExpiry,
      counterpartyExpiry: counterpartyExpiry,
      partyAssets: partyAssets,
      counterpartyAssets: counterpartyAssets
    });
  }

  /// @notice Creates a simple QuipTerms struct with same addresses for signatory/recipient
  /// @param party The party's address
  /// @param counterparty The counterparty's address
  /// @param partyExpiry The party's expiry timestamp
  /// @param counterpartyExpiry The counterparty's expiry timestamp
  /// @param partyAssets The party's assets array
  /// @param counterpartyAssets The counterparty's assets array
  /// @return terms The constructed QuipTerms struct
  function makeSimpleQuipTerms(
    address party,
    address counterparty,
    uint64 partyExpiry,
    uint64 counterpartyExpiry,
    Asset[] memory partyAssets,
    Asset[] memory counterpartyAssets
  ) internal pure returns (QuipTerms memory terms) {
    terms = makeQuipTerms(
      party,
      party, // partyRecipient == party
      counterparty,
      counterparty, // counterpartyRecipient == counterparty
      partyExpiry,
      counterpartyExpiry,
      partyAssets,
      counterpartyAssets
    );
  }
}
