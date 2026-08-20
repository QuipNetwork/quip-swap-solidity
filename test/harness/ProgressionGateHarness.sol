// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ProgressionGate} from '../../src/protocol/CommitValidation.sol';
import {ProtocolTerms} from '../../src/protocol/ProtocolTypes.sol';

contract ProgressionGateHarness {
  function validate(ProtocolTerms calldata terms, bytes32 secret) external pure {
    ProgressionGate.validate(terms, secret);
  }
}
