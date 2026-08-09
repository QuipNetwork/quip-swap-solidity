// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ProtocolTerms, VerifiedCommitAuthorization} from '../ProtocolTypes.sol';

interface ICommitAuthorizationReceiver {
  function receiveAuthorizedCommit(
    ProtocolTerms calldata terms,
    bool party,
    bytes32 lock,
    VerifiedCommitAuthorization calldata evidence,
    bytes calldata commitData
  ) external;
}
