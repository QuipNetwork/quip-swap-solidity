// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ProgressionGate} from '../../src/ProgressionGate.sol';
import {ProtocolTerms} from '../../src/ProtocolTypes.sol';

contract ProgressionGateHarness {
  function validate(ProtocolTerms calldata terms, bool party, bytes32 secret) external pure {
    ProgressionGate.validate(terms, party, secret);
  }
}
