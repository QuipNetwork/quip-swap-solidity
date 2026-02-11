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
# Deployment - Local (Anvil)
# ==============================================================================

ANVIL_RPC_URL := http://127.0.0.1:8545

.PHONY: deploy-local
deploy-local: ## Deploy QuipPortal to local Anvil
	forge script script/DeployQuipPortal.s.sol \
		--rpc-url $(ANVIL_RPC_URL) \
		--broadcast

.PHONY: deploy-mocks-local
deploy-mocks-local: ## Deploy mock tokens to local Anvil
	forge script script/DeployMocks.s.sol \
		--rpc-url $(ANVIL_RPC_URL) \
		--broadcast

.PHONY: mint-erc20-local
mint-erc20-local: ## Mint ERC20 locally. Usage: make mint-erc20-local TOKEN=0x... TO=0x... AMOUNT=1000000000000000000000
	forge script script/MintMocks.s.sol -s "mintERC20(address,address,uint256)" $(TOKEN) $(TO) $(AMOUNT) --rpc-url $(ANVIL_RPC_URL) --broadcast

.PHONY: mint-erc721-local
mint-erc721-local: ## Mint ERC721 locally. Usage: make mint-erc721-local TOKEN=0x... TO=0x... ID=1
	forge script script/MintMocks.s.sol -s "mintERC721(address,address,uint256)" $(TOKEN) $(TO) $(ID) --rpc-url $(ANVIL_RPC_URL) --broadcast

.PHONY: mint-erc1155-local
mint-erc1155-local: ## Mint ERC1155 locally. Usage: make mint-erc1155-local TOKEN=0x... TO=0x... ID=1 AMOUNT=100
	forge script script/MintMocks.s.sol -s "mintERC1155(address,address,uint256,uint256)" $(TOKEN) $(TO) $(ID) $(AMOUNT) --rpc-url $(ANVIL_RPC_URL) --broadcast

# ==============================================================================
# Deployment - Base Sepolia
# ==============================================================================

.PHONY: deploy-base-sepolia
deploy-base-sepolia: ## Deploy QuipPortal to Base Sepolia
	forge script script/DeployQuipPortal.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify

.PHONY: deploy-base-sepolia-dry
deploy-base-sepolia-dry: ## Dry run deployment to Base Sepolia
	forge script script/DeployQuipPortal.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL)

.PHONY: deploy-mocks-base-sepolia
deploy-mocks-base-sepolia: ## Deploy mock tokens to Base Sepolia
	forge script script/DeployMocks.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast

.PHONY: mint-erc20-base-sepolia
mint-erc20-base-sepolia: ## Mint ERC20 on Base Sepolia. Usage: make mint-erc20-base-sepolia TOKEN=0x... TO=0x... AMOUNT=1000000000000000000000
	forge script script/MintMocks.s.sol -s "mintERC20(address,address,uint256)" $(TOKEN) $(TO) $(AMOUNT) --rpc-url $(BASE_SEPOLIA_RPC_URL) --broadcast

.PHONY: mint-erc721-base-sepolia
mint-erc721-base-sepolia: ## Mint ERC721 on Base Sepolia. Usage: make mint-erc721-base-sepolia TOKEN=0x... TO=0x... ID=1
	forge script script/MintMocks.s.sol -s "mintERC721(address,address,uint256)" $(TOKEN) $(TO) $(ID) --rpc-url $(BASE_SEPOLIA_RPC_URL) --broadcast

.PHONY: mint-erc1155-base-sepolia
mint-erc1155-base-sepolia: ## Mint ERC1155 on Base Sepolia. Usage: make mint-erc1155-base-sepolia TOKEN=0x... TO=0x... ID=1 AMOUNT=100
	forge script script/MintMocks.s.sol -s "mintERC1155(address,address,uint256,uint256)" $(TOKEN) $(TO) $(ID) $(AMOUNT) --rpc-url $(BASE_SEPOLIA_RPC_URL) --broadcast

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
