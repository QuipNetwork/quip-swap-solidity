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
deploy-local: ## Deploy to local Anvil (requires DEPLOYER_PK, PORTAL_ADMIN, SENDER)
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
	forge script script/DeployProduction.s.sol \
		--rpc-url $(RPC_URL) \
		--sender $(SENDER) \
		--broadcast \

.PHONY: deploy-production-dry
deploy-production-dry: ## Dry run production deployment. Usage: make deploy-production-dry RPC=BASE_RPC_URL
	forge script script/DeployProduction.s.sol \
		--rpc-url $(RPC_URL) \
		--sender $(SENDER)

# ==============================================================================
# Utilities
# ==============================================================================

.PHONY: snapshot
snapshot: ## Generate gas snapshot
	forge snapshot

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
