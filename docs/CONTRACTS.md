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
| `BatchRegistry` | owner, sequencer, SP1 verifier, fraud/checkpoint vkeys, challenge window, challenge bond | Non-zero owner/sequencer/verifier, non-zero window, bond at least `100000 ether`. |
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
- `FeeDispatcher` retains undistributed shares and failed recipient transfers instead of reverting the entire distribution.
- `Ledger` pushes the dispatcher share and sends the remainder directly to treasury. Fee records are keyed by unique `refId`.
- `Staking` keeps principal, scheduled rewards, and parked rewards reserved. It exposes no owner withdrawal path. New stakes are blocked while paused, but exits remain available.
- `Vault` accepts public org deposits, but native float deposits require `FLOAT_DEPOSITOR_ROLE`.
- `BridgedNFTs` blocks holder transfers until sovereignty is granted or force-claimed. A pending force request also blocks sequencer transfer/burn.

## Upgrade Operations

Direct upgrade scripts currently exist for `BatchRegistry`, `FeeDispatcher`, and `BridgedNFTs`. `DeployLedgerImpl` deploys a Ledger implementation for an out-of-band multisig upgrade.

Every direct upgrade script requires `DEPLOYER_ADDRESS` to be the current proxy owner. Always review storage-layout compatibility before upgrading to a changed implementation.
