// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CommitAuth} from '../../src/interfaces/IOmnibus.sol';

/// @title AuthHelper
/// @notice the ONE definition of test CommitAuth building (mirrors
/// AssetHelper/TermsHelper): every suite calls these directly
library AuthHelper {
  /// @notice keyed ERC-7913 CommitAuth: verifier(20) ‖ account-as-key, empty
  /// envelope (for accept-all mock verifiers, which ignore the signature)
  function keyedAuth(address verifier, address account) internal pure returns (CommitAuth memory) {
    return CommitAuth({signer: abi.encodePacked(verifier, account), signature: ''});
  }

  /// @notice CommitAuth from a prebuilt signer blob, empty envelope
  function auth(bytes memory signer) internal pure returns (CommitAuth memory) {
    return CommitAuth({signer: signer, signature: ''});
  }
}
