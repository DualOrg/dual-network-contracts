SHELL := /bin/bash
.DEFAULT_GOAL := help

# Load local configuration when present. Keep endpoints and credentials in .env
# or pass them on the make command line.
ifneq (,$(wildcard .env))
	include .env
	export $(shell sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' .env)
endif

RPC_URL ?=
PRIVATE_KEY ?=
CHAIN_ID ?=
VERIFIER ?= blockscout
VERIFIER_URL ?=
ETHERSCAN_API_KEY ?=

FORGE_VERBOSITY ?= -vvvv
FORGE_SCRIPT_FLAGS ?=
BROADCAST_FLAGS ?= --broadcast

SCRIPT_all := script/DeployAll.s.sol:DeployAll
SCRIPT_core := script/DeployCore.s.sol:DeployCore
SCRIPT_vault := script/DeployVault.s.sol:DeployVault
SCRIPT_fee-dispatcher := script/DeployFeeDispatcher.s.sol:DeployFeeDispatcher
SCRIPT_staking := script/DeployStaking.s.sol:DeployStaking
SCRIPT_ledger := script/DeployLedger.s.sol:DeployLedger
SCRIPT_batch-registry := script/DeployBatchRegistry.s.sol:DeployBatchRegistry
SCRIPT_bridged-nfts := script/DeployBridgedNFTs.s.sol:DeployBridgedNFTs
SCRIPT_ledger-impl := script/DeployLedgerImpl.s.sol:DeployLedgerImpl

SCRIPT_upgrade-batch-registry := script/UpgradeBatchRegistry.s.sol:UpgradeBatchRegistry
SCRIPT_upgrade-fee-dispatcher := script/UpgradeFeeDispatcher.s.sol:UpgradeFeeDispatcher
SCRIPT_upgrade-bridged-nfts := script/UpgradeBridgedNFTs.s.sol:UpgradeBridgedNFTs
SCRIPT_grant-sender-role := script/GrantSenderRole.s.sol:GrantSenderRole

DEPLOY_KEYS := all core vault fee-dispatcher staking ledger batch-registry bridged-nfts ledger-impl
UPGRADE_KEYS := batch-registry fee-dispatcher bridged-nfts

COMMON_ARGS = --rpc-url "$(RPC_URL)" $(FORGE_VERBOSITY) $(FORGE_SCRIPT_FLAGS)
PRIVATE_KEY_ARGS = --private-key "$(PRIVATE_KEY)"
VERIFY_ARGS = --verify --verifier "$(VERIFIER)" --verifier-url "$(VERIFIER_URL)"

ifneq ($(strip $(CHAIN_ID)),)
	COMMON_ARGS += --chain-id "$(CHAIN_ID)"
endif

ifneq ($(strip $(ETHERSCAN_API_KEY)),)
	VERIFY_ARGS += --etherscan-api-key "$(ETHERSCAN_API_KEY)"
endif

define require-script
	@if [ -z "$(strip $(SCRIPT_$(1)))" ]; then echo "ERROR: unknown script key '$(1)'"; exit 1; fi
endef

.PHONY: help
help:
	@echo "Build and test:"
	@echo "  make build | test | fmt | check"
	@echo ""
	@echo "Deployments:"
	@echo "  make dry-run-<name> | deploy-<name> | verify-<name>"
	@echo "  names: $(DEPLOY_KEYS)"
	@echo ""
	@echo "Direct upgrades:"
	@echo "  make dry-run-upgrade-<name> | upgrade-<name> | verify-upgrade-<name>"
	@echo "  names: $(UPGRADE_KEYS)"
	@echo ""
	@echo "Utilities:"
	@echo "  make dry-run-grant-sender-role | grant-sender-role"
	@echo "  make staking-info"
	@echo ""
	@echo "Required make vars:"
	@echo "  RPC_URL; PRIVATE_KEY for broadcasts; VERIFIER_URL for verification"
	@echo "Optional make vars:"
	@echo "  CHAIN_ID, VERIFIER, ETHERSCAN_API_KEY, FORGE_SCRIPT_FLAGS, BROADCAST_FLAGS"
	@echo "Contract/script vars are documented in docs/DEPLOYMENT.md and .env.example."

.PHONY: build test fmt check
build:
	forge build

test:
	forge test

fmt:
	forge fmt

check: build test

.PHONY: require-rpc require-private-key require-verifier-url require-staking-address
require-rpc:
	@if [ -z "$(strip $(RPC_URL))" ]; then echo "ERROR: RPC_URL not set"; exit 1; fi

require-private-key:
	@if [ -z "$(strip $(PRIVATE_KEY))" ]; then echo "ERROR: PRIVATE_KEY not set"; exit 1; fi

require-verifier-url:
	@if [ -z "$(strip $(VERIFIER_URL))" ]; then echo "ERROR: VERIFIER_URL not set"; exit 1; fi

require-staking-address:
	@if [ -z "$(strip $(STAKING_ADDRESS))" ]; then echo "ERROR: STAKING_ADDRESS not set"; exit 1; fi

.PHONY: dry-run-% deploy-% verify-%
dry-run-%: require-rpc
	$(call require-script,$*)
	forge script "$(SCRIPT_$*)" $(COMMON_ARGS)

deploy-%: require-rpc require-private-key
	$(call require-script,$*)
	@forge script "$(SCRIPT_$*)" $(COMMON_ARGS) $(PRIVATE_KEY_ARGS) $(BROADCAST_FLAGS)

verify-%: require-rpc require-private-key require-verifier-url
	$(call require-script,$*)
	@forge script "$(SCRIPT_$*)" $(COMMON_ARGS) $(PRIVATE_KEY_ARGS) $(BROADCAST_FLAGS) $(VERIFY_ARGS)

.PHONY: dry-run-upgrade-% upgrade-% verify-upgrade-%
dry-run-upgrade-%: require-rpc
	$(call require-script,upgrade-$*)
	forge script "$(SCRIPT_upgrade-$*)" $(COMMON_ARGS)

upgrade-%: require-rpc require-private-key
	$(call require-script,upgrade-$*)
	@forge script "$(SCRIPT_upgrade-$*)" $(COMMON_ARGS) $(PRIVATE_KEY_ARGS) $(BROADCAST_FLAGS)

verify-upgrade-%: require-rpc require-private-key require-verifier-url
	$(call require-script,upgrade-$*)
	@forge script "$(SCRIPT_upgrade-$*)" $(COMMON_ARGS) $(PRIVATE_KEY_ARGS) $(BROADCAST_FLAGS) $(VERIFY_ARGS)

.PHONY: dry-run-grant-sender-role grant-sender-role staking-info
dry-run-grant-sender-role: require-rpc
	forge script "$(SCRIPT_grant-sender-role)" $(COMMON_ARGS)

grant-sender-role: require-rpc require-private-key
	@forge script "$(SCRIPT_grant-sender-role)" $(COMMON_ARGS) $(PRIVATE_KEY_ARGS) $(BROADCAST_FLAGS)

staking-info: require-rpc require-staking-address
	bash script/staking-info.sh
