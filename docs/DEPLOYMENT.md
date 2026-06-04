# Deployment Guide

## Network Variables

The Makefile does not contain a network or explorer URL.

| Variable | Used for |
| --- | --- |
| `RPC_URL` | Every dry-run, broadcast, verification, and read-only utility. |
| `PRIVATE_KEY` | Broadcast and verification targets. |
| `CHAIN_ID` | Optional explicit chain ID passed to Forge. |
| `VERIFIER` | Forge verifier name; defaults to `blockscout`. |
| `VERIFIER_URL` | Verification endpoint; required by `make verify-*`. |
| `ETHERSCAN_API_KEY` | Optional verifier API key. |
| `FORGE_SCRIPT_FLAGS` | Optional extra Forge script flags, such as `--legacy`. |
| `BROADCAST_FLAGS` | Broadcast flags; defaults to `--broadcast`. |

Copy `.env.example` to `.env`, uncomment the variables you need, and set their values.

## Script Matrix

| Script key / command | Required contract variables | Optional contract variables |
| --- | --- | --- |
| `all` | `ZK_VERIFIER_ADDRESS`, `FRAUD_PROOF_VKEY`, `CHECKPOINT_VKEY`, `STAKING_BPS`, `TREASURY_BPS`, `NFT_BASE_URI` | Shared identities, challenge config, rewards duration, treasury. |
| `core` | `STAKING_BPS`, `TREASURY_BPS` | Shared identities, rewards duration, treasury. |
| `vault` | None | `DEPLOYER_ADDRESS`, `OWNER_ADDRESS`. |
| `fee-dispatcher` | None | `OWNER_ADDRESS`, `VAULT_ADDRESS`, `BATCH_REGISTRY_ADDRESS`, `LEDGER_ADDRESS`. |
| `staking` | `FEE_DISPATCHER_ADDRESS` | `OWNER_ADDRESS`, `REWARDS_DURATION`. |
| `ledger` | `LEDGER_SENDER_ADDRESS`, `TREASURY_ADDRESS` | `OWNER_ADDRESS`, `FEE_DISPATCHER_ADDRESS`. |
| `batch-registry` | `ZK_VERIFIER_ADDRESS`, `FRAUD_PROOF_VKEY`, `CHECKPOINT_VKEY` | `OWNER_ADDRESS`, `SEQUENCER_ADDRESS`, challenge config. |
| `bridged-nfts` | `NFT_BASE_URI` | `OWNER_ADDRESS`, `SEQUENCER_NFT_ADDRESS`. |
| `ledger-impl` | None | `LEDGER_PROXY_ADDRESS` for pre-upgrade state logging. |

Shared identity defaults use `DEPLOYER_ADDRESS`, which itself defaults to the Forge sender.

`DeployAll` and `DeployCore` wire contracts through `onlyOwner` calls, so their `OWNER_ADDRESS` must equal `DEPLOYER_ADDRESS`. `STAKING_BPS` must be non-zero, and the staking plus treasury shares cannot exceed 10,000.

Single-contract scripts that automatically wire an existing contract also enforce ownership:

- `DeployFeeDispatcher` requires the deployer to own `VAULT_ADDRESS` when provided.
- `DeployLedger` requires the deployer to own `FEE_DISPATCHER_ADDRESS` when provided.

## Make Targets

For each deployment key in `make help`:

```shell
make dry-run-<key>
make deploy-<key>
make verify-<key>
```

Examples:

```shell
make dry-run-all
make deploy-vault
make verify-bridged-nfts
make deploy-ledger-impl
```

Verification targets broadcast and verify in one command. Set `VERIFIER_URL`; add `ETHERSCAN_API_KEY` only when the verifier requires it.

## Upgrades

| Target name | Required proxy variable |
| --- | --- |
| `upgrade-batch-registry` | `BATCH_REGISTRY_PROXY_ADDRESS` |
| `upgrade-fee-dispatcher` | `FEE_DISPATCHER_PROXY_ADDRESS` |
| `upgrade-bridged-nfts` | `BRIDGED_NFTS_PROXY_ADDRESS` |

Each has `dry-run-` and `verify-` variants. The broadcasting deployer must be the proxy owner.

For a multisig-controlled Ledger, deploy a new implementation with `make deploy-ledger-impl`, review its address and bytecode, then execute `upgradeToAndCall(newImplementation, "")` from the multisig.

## Operational Utilities

Grant Ledger sender access:

```shell
LEDGER_ADDRESS=0x... GRANTEE_ADDRESS=0x... make dry-run-grant-sender-role
LEDGER_ADDRESS=0x... GRANTEE_ADDRESS=0x... make grant-sender-role
```

The deployer must own the Ledger. The script calls the contract's `grantSenderRole` owner wrapper.

Read Staking state:

```shell
STAKING_ADDRESS=0x... make staking-info
```

## Post-Deployment Checks

For a complete deployment, verify:

1. Every proxy owner is the intended operational owner.
2. `Vault.feeDispatcher()` equals the FeeDispatcher proxy.
3. `FeeDispatcher.vault()`, `batchRegistry()`, and `ledger()` point to the expected proxies.
4. `BatchRegistry.feeDispatcher()` equals the FeeDispatcher proxy.
5. `Staking.feeDispatcher()` equals the FeeDispatcher proxy.
6. FeeDispatcher recipients and total basis points match the approved allocation.
7. Ledger treasury, dispatcher split, and `SENDER_ROLE` assignments are correct.
8. BatchRegistry verifier, vkeys, sequencer, challenge window, and challenge bond are correct.
9. BridgedNFTs sequencer and base URI are correct.
