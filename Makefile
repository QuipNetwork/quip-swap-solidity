# ==============================================================================
# Quip Swap Makefile
# ==============================================================================
# Load .env file if it exists
-include .env

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
# Deployment - Base Sepolia
# ==============================================================================

.PHONY: deploy-base-sepolia
deploy-base-sepolia: ## Deploy to Base Sepolia
	forge script script/DeployQuipPortal.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify

.PHONY: deploy-base-sepolia-dry
deploy-base-sepolia-dry: ## Dry run deployment to Base Sepolia
	forge script script/DeployQuipPortal.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL)

# ==============================================================================
# Utilities
# ==============================================================================

.PHONY: snapshot
snapshot: ## Generate gas snapshot
	forge snapshot

.PHONY: anvil
anvil: ## Start local Anvil node
	anvil

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
