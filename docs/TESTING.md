# Testing Guide

## Full Suite

```shell
forge test
```

The full suite compiles contracts and scripts, then runs all unit, integration, adversarial, invariant, arithmetic-property, and end-to-end tests.

## Focused Suites

| Suite | Files | Responsibility |
| --- | --- | --- |
| Unit and coverage | `test/<Contract>.t.sol`, `test/BatchRegistryCoverage.t.sol` | Initializers, permissions, state transitions, events, and revert paths. |
| Integration | `test/*Integration.t.sol` | Cross-contract fee movement and adversarial receiver behavior. |
| Invariant | `test/*Invariant.t.sol` | Conservation, solvency, accounting reconciliation, and token/NFT consistency. |
| Arithmetic property | `test/*Symbolic.t.sol`, `test/StakingNotifySymbolic.t.sol` | Bounded arithmetic and reward-scheduling properties under fuzzed inputs. |
| End to end | `test/SystemE2E.t.sol` | Complete BatchRegistry and Ledger fee paths through FeeDispatcher into Staking. |

Useful commands:

```shell
forge test --match-path 'test/*Integration.t.sol'
forge test --match-path 'test/*Invariant.t.sol'
forge test --match-path 'test/*Symbolic.t.sol'
forge test --match-contract SystemE2ETest
forge test --match-contract StakingTest -vvv
```

## Script Verification

Every Solidity script is compiled by `forge build` and `forge test`. Before broadcasting, run the matching Make dry-run against the intended RPC:

```shell
make dry-run-all
make dry-run-upgrade-fee-dispatcher
make dry-run-grant-sender-role
```

Dry-runs are especially important for scripts that wire existing contracts because those operations require the broadcasting account to be the current owner.

## Coverage Boundaries

The current suite does not explicitly test UUPS upgrade authorization and state
preservation, repeated initialization attempts, or the two-step ownership
transfer lifecycle. `Vault` combines ownership with `AccessControl`; ownership
transfers do not automatically move `DEFAULT_ADMIN_ROLE`. `Ledger` uses
`AccessControl` for `SENDER_ROLE`, but grants no `DEFAULT_ADMIN_ROLE`; its
owner-only wrapper manages sender-role grants.

## Formatting

```shell
forge fmt
forge fmt --check
```

Run formatting intentionally because it may touch contracts and tests outside the functional change being made.
