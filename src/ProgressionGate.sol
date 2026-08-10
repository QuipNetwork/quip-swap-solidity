// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ProtocolHashing} from './ProtocolHashing.sol';
import {ProtocolTerms, WrapperMode} from './ProtocolTypes.sol';

library ProgressionGate {
  error InvalidProgressionTerms();
  error MissingBobCommitSecret();
  error InvalidBobCommitSecret();
  error UnexpectedBobCommitSecret();

  function validate(ProtocolTerms memory terms, bool party, bytes32 bobCommitSecret) internal pure {
    if (terms.partySide.commitLock != bytes32(0)) revert InvalidProgressionTerms();
    WrapperMode mode = ProtocolHashing.mode(terms);
    if (mode == WrapperMode.SameChain) {
      if (terms.counterpartySide.commitLock != bytes32(0)) revert InvalidProgressionTerms();
      if (bobCommitSecret != bytes32(0)) revert UnexpectedBobCommitSecret();
      return;
    }
    if (terms.counterpartySide.commitLock == bytes32(0)) revert InvalidProgressionTerms();
    if (party) {
      if (bobCommitSecret != bytes32(0)) revert UnexpectedBobCommitSecret();
      return;
    }
    if (bobCommitSecret == bytes32(0)) revert MissingBobCommitSecret();
    bytes32 contextId = ProtocolHashing.gateContextId(terms);
    if (ProtocolHashing.commitLock(contextId, bobCommitSecret) != terms.counterpartySide.commitLock) {
      revert InvalidBobCommitSecret();
    }
  }
}
