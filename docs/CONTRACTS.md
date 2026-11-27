# Contract Architecture

## Topology

```text
Vault --batch DUAL--> FeeDispatcher --configured shares--> Staking / treasury / other recipients
Ledger --ledger DUAL-> FeeDispatcher --configured shares--> Staking / treasury / other recipients
Ledger ----------------direct remainder------------------> Ledger treasury
BatchRegistry --------dispatch request-------------------> FeeDispatcher
```

`BridgedNFTs` is independent of the fee flow.

All contracts are initialized behind UUPS proxies. The implementation constructors disable initializers, and `_authorizeUpgrade` is restricted to the owner.

## Initializers

| Contract | Initializer inputs | Required constraints |
| --- | --- | --- |
| `BatchRegistry` | owner, sequencer, SP1 verifier, fraud/checkpoint vkeys, challenge window, challenge bond; then `reinitializeCheckpoints` (pending batch hashes, bond floor, `maxCheckpointBatches`) | Non-zero owner/sequencer/verifier, non-zero window. `reinitializeCheckpoints` is owner-only, runs once, and needs the bond at or above the floor, a non-zero floor and `maxCheckpointBatches`, and the hash of every batch after the last checkpoint. |
| `FeeDispatcher` | owner, vault, batch registry, ledger | Owner is required; topology addresses may be zero and configured later. |
| `Ledger` | owner/admin, fee dispatcher, sender, treasury | Owner/admin, sender, and treasury are required; dispatcher may be zero. |
| `Staking` | owner, fee dispatcher, rewards duration | Owner and dispatcher are required; duration must be between one hour and 30 days. |
| `Vault` | owner | Owner is required and receives `DEFAULT_ADMIN_ROLE`. |
| `BridgedNFTs` | name, symbol, sequencer, owner, base URI | Sequencer and owner are required. Public `name()` and `symbol()` are always `Dual Network NFT` and `DNFT`. |

## Permissions

| Contract | Privileged actors |
| --- | --- |
| `BatchRegistry` | Owner configures/upgrades/pauses; sequencer commits batches. |
| `FeeDispatcher` | Owner configures/upgrades/pauses; only configured BatchRegistry or Ledger can dispatch. |
| `Ledger` | Owner funds/configures/upgrades/pauses; `SENDER_ROLE` processes fee records. |
| `Staking` | Owner configures/upgrades/pauses/adds bonuses; only FeeDispatcher may send fee rewards through `receive()`. |
| `Vault` | Owner configures/upgrades/pauses/withdraws; `FLOAT_DEPOSITOR_ROLE` deposits float; only FeeDispatcher pulls fees. |
| `BridgedNFTs` | Owner configures/upgrades/pauses; sequencer manages non-sovereign NFTs; holders manage sovereignty requests. |

## Important Behaviors

- `BatchRegistry` parks failed fee dispatches for permissionless retry and reserves active challenge bonds and pending withdrawals.
- `BatchRegistry` challenge bonds: the owner sets a floor (`setMinChallengeBond`); `setChallengeConfig` refuses a bond below it.
- `BatchRegistry.finalizeCheckpoint` (permissionless, proof-gated) finalizes batches with a validity checkpoint; see below. `recordCheckpoint` reverts with `UseFinalizeCheckpoint`.

## BatchRegistry Checkpoints

`finalizeCheckpoint(proofBytes, publicValues, dataUri)` verifies an SP1 proof against `checkpointVKey` over the batch range (start, end]: the start batch is the last one already covered, the end batch the last one proved. `publicValues` is `abi.encode(bytes32 startHash, bytes32 startIntegrityRoot, bytes32 endHash, bytes32 rootsDigest)`:

- `startHash` is the `prev_hash` of the first proved batch and must equal `lastCheckpointBatchHash`;
- `startIntegrityRoot` is the `prev_root` of the first proved batch, the stored root of the start batch;
- `endHash` is the hash of the last proved batch;
- `rootsDigest` is `sha256(integrityRoot_{start+1} || ... || integrityRoot_end)`, the stored roots of every batch in the range, 32 bytes each, in batch number order (SHA-256 precompile). It binds every stored root of the range, the end root included.

It requires:

- `startHash == lastCheckpointBatchHash` and the start batch at or below `highestFinalizedBatchNumber` (else `ChainBroken`);
- `endHash` a committed batch with a higher batch number than the start (else `InvalidInput`);
- end number minus start number at most `maxCheckpointBatches` (else `CheckpointRangeTooLong`);
- `startIntegrityRoot` equal to the stored start root and `rootsDigest` equal to the digest of the stored roots (else `InvalidProof`);
- a `batchHashByNumber` entry for every batch in the range, and no already finalized batch above `highestFinalizedBatchNumber` (else `ChainBroken`).

It then finalizes every batch from `highestFinalizedBatchNumber + 1` to the end batch, in order, through the same path as `finalizeBatch` (fee dispatch included). Batches already finalized are skipped. A challenged batch in the range has its challenge cleared and its bond credited to the sequencer (`ChallengeResolved(n, true, bond)`), as `resolveChallenge` does when the sequencer was correct; a batch whose stored root is not the proved root makes the digest differ, so the checkpoint reverts and `resolveChallenge` decides. It is blocked while paused. The loop walks `batchHashByNumber`, which `commitBatch` writes and the upgrade backfills for the batches after the last phase A checkpoint.

Events a verifier reads for the checkpoint chain (protocol V4 spec 11.2, continuity check):

| Event | When | Meaning |
| --- | --- | --- |
| `CheckpointStateRewritten` | owner `setCheckpointState` | The checkpoint chain was rewritten; the verifier accepts exactly one, the V4 cutover. `reinitializeCheckpoints` never emits it. |
| `CheckpointRecorded(start, end, ...)` | phase A `recordCheckpoint`, before the upgrade | A phase A checkpoint link. No longer emitted. |
| `FinalizingCheckpointsStarted(start, number)` | once, in `reinitializeCheckpoints` | The phase C start: `start` is `lastCheckpointBatchHash`, the end of the last phase A checkpoint (or the cutover batch). |
| `CheckpointFinalized(start, end, number, proofHash, dataUri)` | every `finalizeCheckpoint` | A finalizing checkpoint link from `start` to `end`. |

Gas (Foundry, `--isolate`, real FeeDispatcher, Vault and Staking, mock verifier): about 108,500 gas per batch in the range, plus about 356,000 fixed; the real SP1 Groth16 verifier adds its own cost. Keep `maxCheckpointBatches` so a full range fits well below the chain's block gas limit.
- `FeeDispatcher` retains undistributed shares and failed recipient transfers instead of reverting the entire distribution.
- `Ledger` pushes the dispatcher share and sends the remainder directly to treasury. Fee records are keyed by unique `refId`.
- `Staking` keeps principal, scheduled rewards, and parked rewards reserved. It exposes no owner withdrawal path. New stakes are blocked while paused, but exits remain available.
- `Vault` accepts public org deposits, but native float deposits require `FLOAT_DEPOSITOR_ROLE`.
- `BridgedNFTs` blocks holder transfers until sovereignty is granted or force-claimed. A pending force request also blocks sequencer transfer/burn.

## Upgrade Operations

Direct upgrade scripts currently exist for `BatchRegistry`, `FeeDispatcher`, and `BridgedNFTs`. `DeployLedgerImpl` deploys a Ledger implementation for an out-of-band multisig upgrade.

Every direct upgrade script requires `DEPLOYER_ADDRESS` to be the current proxy owner. Always review storage-layout compatibility before upgrading to a changed implementation.

The BatchRegistry checkpoint upgrade (`reinitializeCheckpoints`) only simulates through Make; see [DEPLOYMENT.md](DEPLOYMENT.md#batchregistry-checkpoint-upgrade). `test/legacy/BatchRegistryV1.sol` is the implementation before it, used by the upgrade tests.
