# ==============================================================================
# Quip Swap Makefile
# ==============================================================================
# Load .env file if it exists, and EXPORT every key into the environment so
# child processes (forge, bun, …) see them — e.g. forge's vm.envAddress reads
# OMNIBUS_OWNER / WALLET_FACTORY without any $(VAR) plumbing.
#
# NOTE: forge loads .env too. Keep FOUNDRY_PROFILE OUT of it — a value there
# would silently apply to `forge test` and `forge build` as well. The deploy
# targets set the profile inline instead.
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

.PHONY: test-fork
# The only test that executes the REAL CreateX bytecode, so it is the one gate
# that can catch a wrong guard formula. Self-skips when API_URL_BASE_SEPOLIA is
# unset (as in CI); the fork block is pinned, so it is cached after first run.
test-fork: ## Validate the CreateX permissioned-salt guard against live factory bytecode (needs API_URL_BASE_SEPOLIA)
	forge test --match-contract Constants_CreateXFork -vv

.PHONY: build-prod
build-prod: ## Build the deployment artifact with the prod profile (out-prod/, metadata stripped)
	FOUNDRY_PROFILE=prod forge build --sizes

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
# quip WalletFactory proxy gating the wallet commit route).)
#
# The deployer EOA is COMPILED IN as Constants.DEPLOYER, not read from env: the
# CreateX salt is permissioned to it, so it is part of the address. DEPLOYER_PK
# must derive it — DeployOmnibus refuses to broadcast otherwise, because CreateX
# would NOT revert on a wrong signer, it would silently deploy elsewhere.
#
# Every deploy path runs under FOUNDRY_PROFILE=prod (metadata-stripped artifact,
# dedicated out-prod/ dir); the deploy script asserts the profile.
#
# Before ANY broadcast, run both free gates:
#   make test-fork RPC=...             validates the guard against live CreateX
#   make deploy-dry RPC=...            must print the address from the registry
#   make deploy-dry-wrong-signer RPC=... must FAIL (proves the gate works)
#
# Per-chain deploy: Omnibus (make deploy). Verifier activation is separate:
# post-deploy, the owner calls setVerifierActivity(verifier, true).
# Local rehearsal: bare Anvil has no CreateX — use `make anvil-fork RPC=...`.
# ==============================================================================

# The deployment artifact's compiler settings are part of what ships, so every
# deploy path pins the profile inline rather than relying on the ambient env.
FOUNDRY_PROD := FOUNDRY_PROFILE=prod

# A well-known PUBLIC key (Anvil account #0) used only to prove the signer gate
# rejects a non-ops key. Never funded, never used for anything real.
WRONG_PK := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

.PHONY: anvil-fork
anvil-fork: ## Start Anvil with fork. Usage: make anvil-fork RPC=API_URL_BASE_SEPOLIA
	anvil --fork-url $(RPC_URL)

.PHONY: deploy
# Recipe lines that carry $(DEPLOYER_PK) are prefixed with @ so make does not
# echo the key into terminal scrollback / CI logs.
deploy: ## Deploy Omnibus + broadcast + verify (needs the canonical hashsigs verifier on-chain first). Usage: make deploy RPC=API_URL_BASE_SEPOLIA
	@$(FOUNDRY_PROD) forge script script/DeployOmnibus.s.sol \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PK) \
		--broadcast \
		--verify

.PHONY: deploy-dry
# Passes --private-key deliberately: it is what makes the rehearsal exercise the
# SAME signer gates (and set the same tx.origin) as the real thing. Nothing is
# sent without --broadcast.
deploy-dry: ## Dry run Omnibus deployment (no broadcast; runs every pre-broadcast gate). Usage: make deploy-dry RPC=API_URL_BASE_SEPOLIA
	@$(FOUNDRY_PROD) forge script script/DeployOmnibus.s.sol \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PK)

.PHONY: deploy-dry-wrong-signer
# The negative rehearsal. Overriding DEPLOYER_PK is exactly what makes this
# work: the derived sender is not Constants.DEPLOYER, so the script must abort
# before broadcasting. Fails at the signer gate, ahead of any RPC-heavy work, so
# it needs no funded account.
deploy-dry-wrong-signer: ## Prove the signer gate works: the SAME command with a non-ops key MUST fail. Usage: make deploy-dry-wrong-signer RPC=API_URL_BASE_SEPOLIA
	@echo 'Rehearsing with a public dev key - this MUST fail...'
	@if $(FOUNDRY_PROD) DEPLOYER_PK=$(WRONG_PK) forge script script/DeployOmnibus.s.sol \
		--rpc-url $(RPC_URL) --private-key $(WRONG_PK) >/dev/null 2>&1; then \
		echo 'FAIL: the deploy script ACCEPTED a non-ops signer'; exit 1; \
	else \
		echo 'OK: the deploy script rejected a non-ops signer'; \
	fi

.PHONY: activate-verifier
activate-verifier: ## Activate an ERC-7913 verifier on the deployed Omnibus (owner action; env: OMNIBUS_OWNER_PK; Omnibus address is derived, not passed). Usage: make activate-verifier RPC=API_URL_BASE_SEPOLIA VERIFIER=0x...
	forge script script/ActivateVerifier.s.sol \
		--sig 'run(address)' $(VERIFIER) \
		--rpc-url $(RPC_URL) \
		--broadcast

# ── Per-chain convenience targets (map to foundry.toml [rpc_endpoints] aliases) ──
# EXPECTED_CHAIN_ID is pinned inline so a mistyped rpc alias aborts before
# broadcasting rather than deploying to the wrong chain.
.PHONY: deploy-base
# MAINNET. Run the full gate sequence first — see the Deployment header above.
deploy-base: ## Deploy Omnibus to Base MAINNET + broadcast + verify (reads env from .env)
	@$(FOUNDRY_PROD) EXPECTED_CHAIN_ID=8453 forge script script/DeployOmnibus.s.sol \
		--rpc-url base \
		--private-key $(DEPLOYER_PK) \
		--broadcast \
		--verify

.PHONY: deploy-base-dry
deploy-base-dry: ## Dry run the Base MAINNET deployment (no broadcast; runs every pre-broadcast gate)
	@$(FOUNDRY_PROD) EXPECTED_CHAIN_ID=8453 forge script script/DeployOmnibus.s.sol \
		--rpc-url base \
		--private-key $(DEPLOYER_PK)

.PHONY: deploy-base-sepolia
deploy-base-sepolia: ## Deploy Omnibus to Base Sepolia + broadcast + verify (reads env from .env)
	@$(FOUNDRY_PROD) EXPECTED_CHAIN_ID=84532 forge script script/DeployOmnibus.s.sol \
		--rpc-url base_sepolia \
		--private-key $(DEPLOYER_PK) \
		--broadcast \
		--verify

.PHONY: deploy-op-sepolia
deploy-op-sepolia: ## Deploy Omnibus to OP Sepolia + broadcast + verify (reads env from .env)
	@$(FOUNDRY_PROD) EXPECTED_CHAIN_ID=11155420 forge script script/DeployOmnibus.s.sol \
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
check: fmt-check build build-prod test test-fork sdk-typecheck sdk-test sdk-build sdk-test-integration ## Run all reasonable checks (Foundry + SDK; cross-chain excluded — run sdk-test-cross-chain separately)

# ==============================================================================
# Utilities
# ==============================================================================

.PHONY: snapshot
snapshot: ## Generate gas snapshot
	forge snapshot

.PHONY: verify-omnibus
# usage:
#   make verify-omnibus                      # uses sdk/src/deployments.json
#   make verify-omnibus FILE=path/to/x.json  # uses a custom file
verify-omnibus: ## Recompute every registry row's address from its version label (no RPC, no env; throws on ANY mismatch incl. the zero placeholder). Optional FILE=path overrides sdk/src/deployments.json.
	$(if $(FILE),DEPLOYMENTS_JSON=$(FILE)) \
	forge script script/VerifyOmnibus.s.sol:VerifyOmnibus -v

.PHONY: verify-omnibus-base
verify-omnibus-base: ## Same as verify-omnibus, pinned to the base mainnet rpc alias (RPC unused; offline predict+compare). Optional FILE=path overrides sdk/src/deployments.json.
	$(if $(FILE),DEPLOYMENTS_JSON=$(FILE)) \
	forge script script/VerifyOmnibus.s.sol:VerifyOmnibus --rpc-url base -v

.PHONY: verify-omnibus-base-sepolia
verify-omnibus-base-sepolia: ## Same as verify-omnibus, pinned to the base_sepolia rpc alias (RPC unused; offline predict+compare). Optional FILE=path overrides sdk/src/deployments.json.
	$(if $(FILE),DEPLOYMENTS_JSON=$(FILE)) \
	forge script script/VerifyOmnibus.s.sol:VerifyOmnibus --rpc-url base_sepolia -v

.PHONY: verify-omnibus-op-sepolia
verify-omnibus-op-sepolia: ## Same as verify-omnibus, pinned to the op_sepolia rpc alias (RPC unused; offline predict+compare). Optional FILE=path overrides sdk/src/deployments.json.
	$(if $(FILE),DEPLOYMENTS_JSON=$(FILE)) \
	forge script script/VerifyOmnibus.s.sol:VerifyOmnibus --rpc-url op_sepolia -v

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
