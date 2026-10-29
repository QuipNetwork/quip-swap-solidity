// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.33;

import {Constants} from './Constants.sol';
import {DeployConstants} from './DeployConstants.sol';
import {VmSafe} from 'forge-std-1.14.0/Vm.sol';

/**
 * @title Deployments
 * @dev Reader for the deployment registry at `sdk/src/deployments.json` — the
 *      one file that records what is deployed where, shared by the Solidity
 *      tooling and the TypeScript SDK so the two cannot disagree.
 *
 *      ONE ROW PER CHAIN, overwritten in place on redeploy. History lives in
 *      git, not in the file. That is deliberate: testnet redeploys are frequent
 *      and a lifecycle model would cost more than it earns right now.
 *
 *      The row's `version` is the salt label. Every consumer re-derives the
 *      address from it via `Constants.predictOmnibus`, so a hand-edited address
 *      is caught rather than trusted — see VerifyOmnibus and the CI copy in
 *      test/Constants/behaviors/predictOmnibus.t.sol.
 *
 *      JSON SHAPE. `vm.parseJson` decodes a struct array by matching JSON keys
 *      to struct FIELD NAMES, so `Deployment` must name its fields exactly as
 *      the file keys them. The fields are kept in alphabetical order to match
 *      the ordering older Foundry versions relied on — it costs nothing and
 *      removes a silent-mis-decode failure mode if the toolchain changes.
 */
library Deployments {
  /// @dev A single chain's Omnibus deployment. Field names and order are load
  ///      bearing: they are the JSON contract (see the note above).
  struct Deployment {
    /// @dev The chain the Omnibus is deployed on.
    uint256 chainId;
    /// @dev Whether an Omnibus is actually live at `omnibus` on that chain.
    ///      The one field `make sync-registry` cannot derive: a CREATE3 address
    ///      is predictable whether or not anything was ever deployed to it, so
    ///      without this a row would advertise an address with no code.
    bool deployed;
    /// @dev The deployed Omnibus address. Zero means "row declared, not yet
    ///      deployed" — the bootstrap case DeployOmnibus fills in.
    address omnibus;
    /// @dev The salt label this deployment was (or will be) deployed under.
    ///      The ONLY input to the address besides CreateX and DEPLOYER.
    string version;
    /// @dev The quip WalletFactory proxy baked into the Omnibus's immutables on
    ///      this chain. Recorded because it is invisible from the address —
    ///      CREATE3 ignores constructor args — and a wrong one permanently
    ///      bricks the wallet commit route.
    address walletFactory;
  }

  /// @dev forge-std exposes the cheatcode address via CommonBase, which a
  ///      library cannot inherit. Only read-only (VmSafe) cheats are used.
  VmSafe private constant VM = VmSafe(address(uint160(uint256(keccak256('hevm cheat code')))));

  /// @notice The registry path, resolved against the repo root.
  /// @dev Lives under sdk/src/ so the SDK can import it directly with
  ///      `resolveJsonModule` and no copy step.
  function defaultPath() internal view returns (string memory) {
    return string.concat(VM.projectRoot(), '/sdk/src/deployments.json');
  }

  /// @notice Every row in the registry, in file order.
  function readAll(string memory jsonPath) internal view returns (Deployment[] memory) {
    return abi.decode(VM.parseJson(VM.readFile(jsonPath), '.deployments'), (Deployment[]));
  }

  /// @notice Every row in the registry at the default path.
  function readAll() internal view returns (Deployment[] memory) {
    return readAll(defaultPath());
  }

  /// @notice The row for `chainId`.
  /// @dev Reverts when absent rather than returning an empty struct: a missing
  ///      row must never read as "chain id 0, address 0, no version".
  function forChain(Deployment[] memory rows, uint256 chainId) internal pure returns (Deployment memory) {
    for (uint256 i; i < rows.length; i++) {
      if (rows[i].chainId == chainId) return rows[i];
    }
    revert('Deployments: no registry row for this chain id (add one to sdk/src/deployments.json)');
  }

  /// @notice Whether the registry has a row for `chainId`.
  function has(Deployment[] memory rows, uint256 chainId) internal pure returns (bool) {
    for (uint256 i; i < rows.length; i++) {
      if (rows[i].chainId == chainId) return true;
    }
    return false;
  }

  /// @notice The rows `make sync-registry` would generate from DeployConstants.
  ///
  /// @dev Every field except `deployed` is derivable, so this is the whole
  ///      registry minus liveness. `deployed` is left false here and compared
  ///      separately (it cannot be recomputed without an RPC).
  function derived() internal pure returns (Deployment[] memory rows) {
    uint256[] memory mainnets = DeployConstants.mainnetChains();
    uint256[] memory testnets = DeployConstants.testnetChains();
    rows = new Deployment[](mainnets.length + testnets.length);

    for (uint256 i; i < rows.length; i++) {
      uint256 chainId = i < mainnets.length ? mainnets[i] : testnets[i - mainnets.length];
      string memory versionLabel = DeployConstants.labelFor(chainId);
      rows[i] = Deployment({
        chainId: chainId,
        deployed: false,
        omnibus: Constants.predictOmnibus(versionLabel),
        version: versionLabel,
        walletFactory: DeployConstants.walletFactoryFor(chainId)
      });
    }
  }

  /// @notice Asserts a parsed registry matches what DeployConstants derives.
  ///
  /// @dev The registry is GENERATED, so any divergence means the committed file
  ///      was hand-edited or a `make sync-registry` was skipped after a
  ///      constants change. Both are silent failures otherwise: the SDK would
  ///      keep shipping stale addresses that still look internally consistent.
  ///      `deployed` is deliberately not compared — it is the one field the
  ///      file is allowed to know more about than the source.
  function requireDerived(Deployment[] memory rows) internal pure {
    Deployment[] memory want = derived();
    require(rows.length == want.length, 'Deployments: registry row count does not match DeployConstants');

    for (uint256 i; i < want.length; i++) {
      require(rows[i].chainId == want[i].chainId, 'Deployments: registry chain ids do not match DeployConstants');
      require(rows[i].omnibus == want[i].omnibus, 'Deployments: registry address is not predictOmnibus(version)');
      require(
        keccak256(bytes(rows[i].version)) == keccak256(bytes(want[i].version)),
        'Deployments: registry version does not match the label for its family'
      );
      require(
        rows[i].walletFactory == want[i].walletFactory,
        'Deployments: registry walletFactory does not match DeployConstants.walletFactoryFor(chainId)'
      );
    }
  }
}
