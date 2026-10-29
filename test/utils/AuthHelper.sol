// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CommitAuth} from '../../src/interfaces/IOmnibus.sol';

/// @title AuthHelper
/// @notice the ONE definition of test CommitAuth building (mirrors
/// AssetHelper/TermsHelper): every suite calls these directly
/// @dev keyed builders carry a NON-EMPTY placeholder envelope on purpose: an
/// empty signature selects the WALLET route, so keyed-route defaults must
/// never be empty (accept-all mock verifiers ignore the bytes anyway)
library AuthHelper {
  /// @notice keyed ERC-7913 CommitAuth: verifier(20) ‖ account-as-key,
  /// placeholder envelope (for accept-all mock verifiers, which ignore it)
  function keyedAuth(address verifier, address account) internal pure returns (CommitAuth memory) {
    return CommitAuth({signer: abi.encodePacked(verifier, account), signature: 'envelope'});
  }

  /// @notice keyed CommitAuth from a prebuilt signer blob, placeholder envelope
  function auth(bytes memory signer) internal pure returns (CommitAuth memory) {
    return CommitAuth({signer: signer, signature: 'envelope'});
  }

  /// @notice wallet-route CommitAuth: the empty signature selects the route;
  /// the signer blob is shape-checked attribution only
  function walletAuth(bytes memory signer) internal pure returns (CommitAuth memory) {
    return CommitAuth({signer: signer, signature: ''});
  }
}
