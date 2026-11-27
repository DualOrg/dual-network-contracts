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

Each has `dry-run-` and `verify-` variants. The broadcasting deployer must be the proxy owner. `upgrade-batch-registry` and `verify-upgrade-batch-registry` refuse to run: the BatchRegistry checkpoint upgrade only simulates (below).

A fresh BatchRegistry from the standalone `DeployBatchRegistry` script must get one owner call after deployment: `reinitializeCheckpoints([], minChallengeBond, maxCheckpointBatches)`. Until then `minChallengeBond` and `maxCheckpointBatches` are `0`: `setChallengeConfig` accepts any bond and every `finalizeCheckpoint` reverts with `CheckpointRangeTooLong`. `DeployAll` makes the call itself, with `MIN_CHALLENGE_BOND` (default: the challenge bond) and `MAX_CHECKPOINT_BATCHES` (default `100`).

### BatchRegistry checkpoint upgrade

The upgrade replaces the constant `MIN_CHALLENGE_BOND` with an owner-set floor, adds `finalizeCheckpoint` and makes `recordCheckpoint` revert. `reinitializeCheckpoints` runs atomically in `upgradeToAndCall` and needs the hash of every batch after the last checkpoint.

Run it only after the V4 cutover, `setCheckpointState(hash(N), batchNumber(N))` in protocol V4 spec 12.1 step 6. The verifier reads the registry log from the cutover block and accepts the one `CheckpointStateRewritten` only before the start event that this upgrade emits; `reinitializer(2)` cannot run again. The first finalizing checkpoint starts at `lastCheckpointBatchHash()`, so it also proves the batches that the window finalized since the last phase A checkpoint.

1. `pause()` the registry (owner). This stops commits, challenges and window finalization while the state is read.
2. Optional, when `batchCount() - lastCheckpointBatchNumber()` is above about 1,000: first record one phase A checkpoint with the old checkpoint program (`recordCheckpoint`, not blocked by the pause) from `lastCheckpointBatchHash()` to the hash of batch `highestFinalizedBatchNumber()`. Prove it on the phase A/B prover image, before the smarttoken phase C release: the phase C prover no longer has that program. It is the checkpoint ELF with SHA-256 `2cbbbdc6d4553c2ae01139c61f706768729da8bf207968548e6e17a2277246b1` and verifying key `0x00867e2c1ab5565d24d96cc36c7ace7af485daaefa7f18dc3bc41554d2263cfc`, which must still be the registry's `checkpointVKey()` at this step. The upgrade transaction writes one backfill entry (about 25,000 gas) per batch after the last checkpoint, so about 1,000 entries fit under a 32M block gas limit (the Nitro default, not checked on chain 6300).
3. Collect the batch hashes read-only. With `L = lastCheckpointBatchNumber()`, `C = batchCount()` and `FROM_BLOCK` at or before the anchoring of batch `L + 1`:

   ```shell
   SIG='BatchAnchored(uint256 indexed,bytes32 indexed,bytes32 indexed,bytes32,bytes32,bytes32,string,uint256,bool)'
   for n in $(seq $((L + 1)) "$C"); do
     cast logs --rpc-url "$RPC_URL" --address "$BATCH_REGISTRY_PROXY_ADDRESS" --from-block "$FROM_BLOCK" \
       --json "$SIG" "$(cast to-uint256 "$n")" | jq -r '.[0].topics[2]'
   done | paste -sd, -
   ```

   The result is `PENDING_BATCH_HASHES` (empty when `L == C`). `getBatchInfo(hash).batchNumber` must equal `n` for each one; the initializer refuses the list otherwise.
4. Simulate:

   ```shell
   BATCH_REGISTRY_PROXY_ADDRESS=0x... DEPLOYER_ADDRESS=<owner> PENDING_BATCH_HASHES=0x...,0x... \
   MIN_CHALLENGE_BOND=<wei> MAX_CHECKPOINT_BATCHES=100 make dry-run-upgrade-batch-registry
   ```

   The script logs the `data` argument of `upgradeToAndCall`. Read the simulated gas of `upgradeToAndCall` before sending; it must stay well below the block gas limit.
5. Deploy the implementation (`src/BatchRegistry.sol:BatchRegistry`), compare its storage layout with `forge inspect BatchRegistry storageLayout`, and send `upgradeToAndCall(implementation, data)` from the owner.
6. Check `minChallengeBond()`, `maxCheckpointBatches()`, `batchHashByNumber(n)` for each pending batch, and the `FinalizingCheckpointsStarted` event: its start hash equals `lastCheckpointBatchHash()`.
7. Lower the bond to its new value with `setChallengeConfig(window, bond)` (bond at or above the floor). Register the finalizing checkpoint program key with `setVKeys` before the first `finalizeCheckpoint`.
8. `unpause()`.

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
8. BatchRegistry verifier, vkeys, sequencer, challenge window, challenge bond, `minChallengeBond`, and `maxCheckpointBatches` are correct.
9. BridgedNFTs sequencer and base URI are correct.
