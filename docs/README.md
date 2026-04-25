# ServiceAgreement docs

Documentation for integrators building against the `ServiceAgreement` contract.

## Where to start

- **[Scenarios](./scenarios.md)** — End-to-end walkthroughs for the common flows: freelance, audit engagement, team-split, dispute, cancellation, operator rotations, upgrades. Read these first.
- **[API reference](./api/index.md)** — Per-function documentation generated from NatSpec. Use this as a precise reference for parameters, return values, and revert conditions.

## Quick orientation

The contract is a milestone-based escrow with the following moving parts:

| Concept | Where it lives | Notes |
|---|---|---|
| **Agreement** | `createAgreement` / `createAgreementFromTemplate` | Created and funded in a single tx by the client. |
| **Milestone** | Inside an agreement | Has a deadline, an amount, and an evidence hash. Paid via `approveMilestone`. |
| **Team split** | `proposeTeam` (provider) + `approveTeam` (client) | Two-sided. Until approved, payouts go to provider. |
| **Dispute** | `raiseDispute` → `resolveDispute` (arbitrator) | Splits remaining escrow per the arbitrator's decision. |
| **Pull payments** | `withdraw(token)` | Recipients claim; nothing is ever pushed. |
| **Timelock** | `scheduleAction` / `executeAction`, `requestUpgrade` | All privileged config + upgrades take 2 days. |

## Building integrations

A typical dapp interacting with `ServiceAgreement` will:

1. **Index events** for the agreements relevant to a user. `getUserAgreements(user)` is fine for small accounts but grows unboundedly; production indexers should use logs.
2. **Render the agreement state** by combining `getAgreementDetails(id)` + `getMilestones(id)` + `getTeam(id)`.
3. **Show pending balances** via `pendingWithdrawals(token, user)` so users know what they can withdraw.
4. **Subscribe to events** (`MilestoneApproved`, `DisputeRaised`, etc.) to surface state changes.

The [Scenarios](./scenarios.md) doc has copy-paste ethers.js v6 sequences for each happy path.

## Operating considerations

- **Token whitelist**: only add standard ERC20 tokens. Fee-on-transfer and rebasing tokens are rejected at deposit. Whitelisting is timelocked.
- **Arbitrator pool**: the contract enforces the pool but not the arbitrator's process. Run arbitrators as a separate decision-making layer (multisig, panel, on-chain court, etc.) and use `setArbitratorPool` to rotate the on-chain set.
- **Owner key**: controls the timelock queue and the upgrade path. Use a multisig in production.
- **Surplus**: Stray ETH or tokens (accidental transfers, SELFDESTRUCT, rebases) are recoverable by the owner via `withdrawSurplus`, which can never touch escrow.

For the security properties enforced by the test suite and Slither, see the top of [`contracts/ServiceAgreement.sol`](../contracts/ServiceAgreement.sol).

## Regenerating these docs

The API reference is generated from NatSpec. Edit the contract, then:

```bash
npm run docs
```

Output goes to `docs/api/index.md`.
