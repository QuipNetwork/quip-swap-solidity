// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CommitAuth} from '../../src/interfaces/IOmnibus.sol';

/// @title AuthHelper
/// @notice the ONE definition of test CommitAuth building (mirrors
/// AssetHelper/TermsHelper): every suite calls these directly
/// @dev keyed builders carry a NON-EMPTY placeholder envelope on purpose: an
/// empty signature selects the ATTESTED route, so keyed-route defaults must
/// never be empty (accept-all mock verifiers ignore the bytes anyway)
library AuthHelper {
  /// @notice keyed ERC-7913 CommitAuth: verifier(20) ‖ account-as-key,
  /// placeholder envelope (for accept-all mock verifiers, which ignore it)
  function keyedAuth(address verifier, address account) internal pure returns (CommitAuth memory) {
    return CommitAuth({signer: abi.encodePacked(verifier, account), signature: 'envelope', walletBinding: bytes32(0)});
  }

  /// @notice keyed CommitAuth from a prebuilt signer blob, placeholder envelope
  function auth(bytes memory signer) internal pure returns (CommitAuth memory) {
    return CommitAuth({signer: signer, signature: 'envelope', walletBinding: bytes32(0)});
  }

  /// @notice attested-route CommitAuth: empty signature selects the route; the
  /// walletBinding witness reconstructs the attested envelope
  function attestedAuth(bytes memory signer, bytes32 walletBinding) internal pure returns (CommitAuth memory) {
    return CommitAuth({signer: signer, signature: '', walletBinding: walletBinding});
  }
}
