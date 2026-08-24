#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

forge coverage --root "$repo_root" --ir-minimum \
  --match-contract "(AssetSupportRegistryTest|AuthorizationBoundariesTest|CommitAuthorizationTest|DeployProtocolTest|DirectAuthorizationTest|ProgressionGateTest|ProtocolHashingTest|SettlementTest|StateMachinesTest|DeployedWrapperGuardsTest|WrapperFundingTest)" \
  --no-match-test "(test_commitSignatureRejectsCrossDeploymentCrossChainAndCrossSideReplay|test_allDemoInvalidActionsRevertAtomicallyInOneSession)" \
  --no-match-coverage "^(src/legacy/|src/interfaces/IOmnibus.sol|script/|test/)" \
  --report summary \
  --report lcov \
  --report-file "${COVERAGE_REPORT:-/tmp/quip-swap-current-protocol.lcov}"
