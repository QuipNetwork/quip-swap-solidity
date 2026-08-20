#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checkpoint_dir="$(mktemp -d "${TMPDIR:-/tmp}/quip-swap-clean-build.XXXXXX")"

cp "$repo_root/foundry.toml" "$checkpoint_dir/foundry.toml"
cp "$repo_root/soldeer.lock" "$checkpoint_dir/soldeer.lock"

restore_config() {
  cp "$checkpoint_dir/foundry.toml" "$repo_root/foundry.toml"
  cp "$checkpoint_dir/soldeer.lock" "$repo_root/soldeer.lock"
  rm -f "$checkpoint_dir/foundry.toml" "$checkpoint_dir/soldeer.lock" "$checkpoint_dir/soldeer.disabled.lock"
  rmdir "$checkpoint_dir"
}
trap restore_config EXIT

# Foundry 1.7.1 can panic while hashing this repository's Soldeer directory.
# The demo profile uses the already-installed lib/ dependencies and avoids that
# tool bug without changing the checked-in configuration.
cp "$repo_root/config/demo/foundry.toml" "$repo_root/foundry.toml"
mv "$repo_root/soldeer.lock" "$checkpoint_dir/soldeer.disabled.lock"

forge coverage --root "$repo_root" --ir-minimum \
  --match-contract "(AssetSupportRegistryTest|AuthorizationBoundariesTest|CommitAuthorizationTest|DeployProtocolTest|DirectAuthorizationTest|ProgressionGateTest|ProtocolHashingTest|SettlementTest|StateMachinesTest|DeployedWrapperGuardsTest|WrapperFundingTest)" \
  --no-match-test "(test_commitSignatureRejectsCrossDeploymentCrossChainAndCrossSideReplay|test_allDemoInvalidActionsRevertAtomicallyInOneSession)" \
  --no-match-coverage "^(src/legacy/|src/interfaces/IOmnibus.sol|script/|test/)" \
  --report summary \
  --report lcov \
  --report-file "${COVERAGE_REPORT:-/tmp/quip-swap-current-protocol.lcov}"

rm -f "$checkpoint_dir/soldeer.disabled.lock"
