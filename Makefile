# ==============================================================================
# Quip Swap Makefile
# ==============================================================================
# Load .env file if it exists, and EXPORT every key into the environment so
# child processes (forge, bun, …) see them — e.g. forge's vm.envAddress reads
# DEPLOYER_ADDRESS / OMNIBUS_OWNER without any $(VAR) plumbing.
# A missing .env is silently ignored (unscoped build/test need none of these).
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

# ==============================================================================
# RPC URL Indirection
# ==============================================================================
# Use indirection: RPC=API_URL_BASE_SEPOLIA will use the value of $(API_URL_BASE_SEPOLIA)
# This allows referencing any RPC URL defined in .env by name
RPC_URL = $($(RPC))

# Local Anvil URL (hardcoded)
ANVIL_RPC_URL := http://127.0.0.1:8545

# ==============================================================================
# Development
# ==============================================================================

.PHONY: build
build: ## Build contracts
	forge build

.PHONY: test
test: ## Run all tests
	forge test

.PHONY: test-v
test-v: ## Run tests with verbosity
	forge test -vvv

.PHONY: test-gas
test-gas: ## Run tests with gas report
	forge test --gas-report

.PHONY: coverage
coverage: ## Generate coverage report
	forge coverage

.PHONY: fmt
fmt: ## Format code
	forge fmt

.PHONY: fmt-check
fmt-check: ## Check formatting
	forge fmt --check

.PHONY: clean
clean: ## Clean build artifacts
	forge clean

# ==============================================================================
# Deployment (via the canonical CreateX factory, pre-deployed on every chain —
# no per-chain bootstrap. env: DEPLOYER_PK, OMNIBUS_OWNER, WALLET_FACTORY (the
# quip WalletFactory proxy gating the wallet commit route); verify-omnibus also
# needs DEPLOYER_ADDRESS = the EOA of DEPLOYER_PK, since the CreateX salt is
# permissioned to it and the predicted address depends on it.)
#
# Per-chain deploy: Omnibus (make deploy). Verifier activation is separate:
# post-deploy, the owner calls setVerifierActivity(verifier, true).
# Local rehearsal: bare Anvil has no CreateX — use `make anvil-fork RPC=...`.
# ==============================================================================

.PHONY: anvil-fork
anvil-fork: ## Start Anvil with fork. Usage: make anvil-fork RPC=API_URL_BASE_SEPOLIA
	anvil --fork-url $(RPC_URL)

.PHONY: deploy
deploy: ## Deploy Omnibus + broadcast + verify (needs the canonical hashsigs verifier on-chain first). Usage: make deploy RPC=API_URL_BASE_SEPOLIA
	forge script script/DeployOmnibus.s.sol \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PK) \
		--broadcast \
		--verify

.PHONY: deploy-dry
deploy-dry: ## Dry run Omnibus deployment (no broadcast). Usage: make deploy-dry RPC=API_URL_BASE_SEPOLIA
	forge script script/DeployOmnibus.s.sol \
		--rpc-url $(RPC_URL)

.PHONY: activate-verifier
activate-verifier: ## Activate an ERC-7913 verifier on the deployed Omnibus (owner action; env: OMNIBUS_OWNER_PK, DEPLOYER_ADDRESS; Omnibus address is predicted). Usage: make activate-verifier RPC=API_URL_BASE_SEPOLIA VERIFIER=0x...
	forge script script/ActivateVerifier.s.sol \
		--sig 'run(address)' $(VERIFIER) \
		--rpc-url $(RPC_URL) \
		--broadcast

# ── Per-chain convenience targets (map to foundry.toml [rpc_endpoints] aliases) ──
.PHONY: deploy-base-sepolia
deploy-base-sepolia: ## Deploy Omnibus to Base Sepolia + broadcast + verify (reads env from .env)
	forge script script/DeployOmnibus.s.sol \
		--rpc-url base_sepolia \
		--private-key $(DEPLOYER_PK) \
		--broadcast \
		--verify

.PHONY: deploy-op-sepolia
deploy-op-sepolia: ## Deploy Omnibus to OP Sepolia + broadcast + verify (reads env from .env)
	forge script script/DeployOmnibus.s.sol \
		--rpc-url op_sepolia \
		--private-key $(DEPLOYER_PK) \
		--broadcast \
		--verify

# ==============================================================================
# TypeScript SDK (sdk/)
# ==============================================================================
# The SDK consumes Foundry artifacts from out/, so sdk-generate depends on a
# fresh `forge build`. Integration and cross-chain targets manage their own
# Anvil nodes (no manual node startup needed).

.PHONY: sdk-install
sdk-install: ## Install SDK dependencies (bun)
	cd sdk && bun install

.PHONY: sdk-generate
sdk-generate: build ## Generate the Omnibus ABI from Foundry artifacts
	cd sdk && bun run generate:abi

.PHONY: sdk-typecheck
sdk-typecheck: ## Typecheck the SDK (strict tsc, no emit)
	cd sdk && bun run typecheck

.PHONY: sdk-test
sdk-test: ## Run SDK unit + mocked-client tests (no chain needed)
	cd sdk && bun run test

.PHONY: sdk-test-integration
sdk-test-integration: ## Run single-chain Anvil integration + differential tests (starts its own Anvil)
	cd sdk && bun run test:integration

.PHONY: sdk-test-cross-chain
sdk-test-cross-chain: ## Run two-chain end-to-end tests (slower; starts two Anvil nodes)
	cd sdk && bun run test:cross-chain

.PHONY: sdk-build
sdk-build: ## Build the publishable SDK bundle (dist/)
	cd sdk && bun run build

# ==============================================================================
# Full Verification
# ==============================================================================

.PHONY: check
check: fmt-check build test sdk-typecheck sdk-test sdk-build sdk-test-integration ## Run all reasonable checks (Foundry + SDK; cross-chain excluded — run sdk-test-cross-chain separately)

# ==============================================================================
# Utilities
# ==============================================================================

.PHONY: snapshot
snapshot: ## Generate gas snapshot
	forge snapshot

.PHONY: verify-omnibus
# usage:
#   make verify-omnibus                      # uses sdk/src/address.json
#   make verify-omnibus FILE=path/to/x.json  # uses a custom file
verify-omnibus: ## Compare an address.json against the CREATE3 address predicted from (CreateX, deployer EOA, salt) (no RPC; throws on ANY mismatch incl. the zero placeholder). Optional FILE=path overrides sdk/src/address.json.
	$(if $(FILE),ADDRESS_JSON=$(FILE)) \
	forge script script/VerifyOmnibus.s.sol:VerifyOmnibus -v

.PHONY: verify-omnibus-base-sepolia
verify-omnibus-base-sepolia: ## Same as verify-omnibus, pinned to the base_sepolia rpc alias (RPC unused; offline predict+compare). Optional FILE=path overrides sdk/src/address.json.
	$(if $(FILE),ADDRESS_JSON=$(FILE)) \
	forge script script/VerifyOmnibus.s.sol:VerifyOmnibus --rpc-url base_sepolia -v

.PHONY: verify-omnibus-op-sepolia
verify-omnibus-op-sepolia: ## Same as verify-omnibus, pinned to the op_sepolia rpc alias (RPC unused; offline predict+compare). Optional FILE=path overrides sdk/src/address.json.
	$(if $(FILE),ADDRESS_JSON=$(FILE)) \
	forge script script/VerifyOmnibus.s.sol:VerifyOmnibus --rpc-url op_sepolia -v

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
