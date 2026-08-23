// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ProtocolTerms, VerifiedCommitAuthorization} from '../protocol/ProtocolTypes.sol';

/// @notice Wrapper callback used by a wallet or direct gateway after authenticating a commit.
interface ICommitAuthorizationReceiver {
  /// @notice Atomically delivers signed commit evidence and funds to the target wrapper.
  function receiveAuthorizedCommit(
    ProtocolTerms calldata terms,
    bool party,
    bytes32 lock,
    bytes32 bobCommitSecret,
    VerifiedCommitAuthorization calldata evidence,
    bytes calldata commitData
  ) external payable;
}
