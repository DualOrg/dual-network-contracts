# DUAL Network Contracts

Upgradeable Solidity contracts for DUAL Network, built and tested with Foundry.

## Contracts

| Contract | Purpose |
| --- | --- |
| `BatchRegistry` | Anchors sequencer batches, verifies SP1 proofs, manages optimistic challenges, records checkpoints, and initiates batch-fee dispatch. |
| `FeeDispatcher` | Pulls batch fees from `Vault`, accepts pushed Ledger fees, and distributes configured basis-point shares. |
| `Ledger` | Records role-gated fee events and splits owner-funded native DUAL between `FeeDispatcher` and treasury. |
| `Staking` | Mints xDUAL 1:1 for native DUAL and streams dispatcher rewards to stakers. |
| `Vault` | Custodies native DUAL and ERC-20 org deposits; only its configured `FeeDispatcher` can pull fee distributions. |
| `BridgedNFTs` | Custodial/sovereign ERC-721 bridge representation with sequencer operations and a seven-day force-sovereignty path. |

All six contracts use UUPS proxies. Upgrades and administrative configuration are authorized by the contract owner.

See [docs/CONTRACTS.md](docs/CONTRACTS.md) for the topology, permissions, and important behavioral constraints.

## Setup

Prerequisites: `forge`, `cast`, and `anvil`.

```shell
forge install
cp .env.example .env
forge build
forge test
```

Fill only the variables needed by the script you plan to run. The complete variable and script matrix is in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Make Commands

```shell
make help
make check

make dry-run-all
make deploy-all
make verify-all

make dry-run-vault
make deploy-vault
make verify-vault

make dry-run-upgrade-batch-registry
make upgrade-batch-registry
make verify-upgrade-batch-registry
```

`RPC_URL`, `PRIVATE_KEY`, `VERIFIER`, `VERIFIER_URL`, `CHAIN_ID`, and `ETHERSCAN_API_KEY` are variables. The Makefile contains no network or explorer endpoint.

`DeployAll` and `DeployCore` configure multiple `onlyOwner` relationships in the deployment transaction, so `OWNER_ADDRESS` must equal `DEPLOYER_ADDRESS` for those scripts. Ownership can be transferred afterward using the contracts' two-step ownership flow.

## Test Suites

The repository contains unit, integration, adversarial, invariant, arithmetic-property, and end-to-end tests.

```shell
forge test
forge test --match-path 'test/*Integration.t.sol'
forge test --match-path 'test/*Invariant.t.sol'
forge test --match-contract SystemE2ETest
```

See [docs/TESTING.md](docs/TESTING.md) for suite responsibilities and focused commands.

## Layout

```text
src/        Contracts, interfaces, and libraries
script/     Deployment, upgrade, and operational scripts
test/       Unit, integration, invariant, and end-to-end tests
docs/       Contract, deployment, and testing documentation
lib/        Foundry dependencies
```
