# ==============================================================================
# Quip Swap Makefile
# ==============================================================================
# Load .env file if it exists
-include .env

# ==============================================================================
# RPC URL Indirection
# ==============================================================================
# Use indirection: RPC=BASE_SEPOLIA_RPC_URL will use the value of $(BASE_SEPOLIA_RPC_URL)
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
# Deployment - Local (Anvil with fork)
# ==============================================================================

.PHONY: anvil-fork
anvil-fork: ## Start Anvil with fork. Usage: make anvil-fork RPC=BASE_SEPOLIA_RPC_URL
	anvil --fork-url $(RPC_URL)

.PHONY: deploy-local
deploy-local: ## Deploy to local Anvil (requires DEPLOYER_PK, SENDER)
	forge script script/DeployTestnet.s.sol \
		--rpc-url $(ANVIL_RPC_URL) \
		--sender $(SENDER) \
		--broadcast

# ==============================================================================
# Deployment - Testnet
# ==============================================================================

.PHONY: deploy-testnet
deploy-testnet: ## Deploy to testnet. Usage: make deploy-testnet RPC=BASE_SEPOLIA_RPC_URL
	forge script script/DeployTestnet.s.sol \
		--rpc-url $(RPC_URL) \
		--sender $(SENDER) \
		--broadcast \
		--verify

.PHONY: deploy-testnet-dry
deploy-testnet-dry: ## Dry run testnet deployment. Usage: make deploy-testnet-dry RPC=BASE_SEPOLIA_RPC_URL
	forge script script/DeployTestnet.s.sol \
		--rpc-url $(RPC_URL) \
		--sender $(SENDER)

# ==============================================================================
# Deployment - Production
# ==============================================================================

.PHONY: deploy-production
deploy-production: ## Deploy to production. Usage: make deploy-production RPC=BASE_RPC_URL
	forge script script/DeployOmnibus.s.sol \
		--rpc-url $(RPC_URL) \
		--sender $(SENDER) \
		--broadcast \
		--verify

.PHONY: deploy-production-dry
deploy-production-dry: ## Dry run production deployment. Usage: make deploy-production-dry RPC=BASE_RPC_URL
	forge script script/DeployOmnibus.s.sol \
		--rpc-url $(RPC_URL) \
		--sender $(SENDER)

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
verify-omnibus: ## Compare an address.json against the locally-predicted Create3 address (no RPC; reads DEPLOYER_PK from .env). Optional FILE=path overrides sdk/src/address.json.
	$(if $(FILE),ADDRESS_JSON=$(FILE)) \
	forge script script/VerifyOmnibus.s.sol:VerifyOmnibus -v

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
