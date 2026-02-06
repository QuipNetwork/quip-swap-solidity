// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

enum Status {
  Open,
  Accepted,
  Committed,
  Claimed,
  Reclaimed,
  Slashed
}

struct QuipTerms {
  address asker;
  address askRecipient;
  address bidder;
  address bidRecipient;
  uint64 askExpiry;
  uint64 bidExpiry;
  bytes askOps;
  bytes bidOps;
}

interface IQuip {

  function version() external view returns (uint256);
  function initialize(bytes32 secretDigest, QuipTerms calldata terms) external;
}
