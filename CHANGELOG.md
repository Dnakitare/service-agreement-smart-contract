# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project (deliberately) stays in `0.x` until a third-party security audit signs off — see the [security note](#security-status).

## [Unreleased]

## [0.3.0] — 2026-04-25

### Added
- Errors reference doc (`docs/errors.md`) mapping every custom error to its cause and integrator handling pattern.
- `MAX_ARBITRATORS = 10` cap on the arbitrator pool plus `TooManyArbitrators` error.
- `notDisputed` modifier — agreement is now structurally frozen during a dispute (no team mutations, no evidence overwrites, no extensions, no cancel).

### Changed
- `extendMilestoneDeadline` now lifts `agreement.deadline` when the new deadline exceeds it. This keeps the provider's dispute window from opening prematurely after the client extends the last milestone as a courtesy.
- `scheduleAction` now reverts with `ActionAlreadyScheduled` (was the misleading `ActionAlreadyExecuted`) when an identical action collides in the same block.

### Security
- Closed all findings from the second adversarial review (2 medium, several lows). 0 critical / 0 high.
- 93 tests passing, 0 Slither findings, 99% statement / 100% function coverage.

## [0.2.0] — 2026-04-24

### Added
- Two-sided team payment authorization: `proposeTeam` (provider) + `approveTeam` (client). Until the client approves, all milestone payouts go to the provider.
- Real timelock on implementation upgrades: `requestUpgrade(impl)` + `cancelUpgradeRequest(impl)`; `_authorizeUpgrade` enforces the 2-day delay.
- Adversarial dispute rule: provider may only `raiseDispute` after `agreement.deadline`; the client may dispute any time.

### Changed
- **Breaking:** `completeMilestone` and `releaseMilestonePayment` are merged into a single atomic `approveMilestone(id, idx)`. The same applies to `batchReleaseMilestonePayments` → `batchApproveMilestones`. Closes the front-run window where a provider could call `raiseDispute` between the client's complete and pay calls; also closes the cancel-after-completion grift.
- **Breaking:** `addTeamMembers` removed. Use `proposeTeam` + `approveTeam`.
- Defensive guard added to `resolveDispute` against `remainingAmount == 0`.

### Security
- Closed all findings from the first adversarial review (2 high, 5 medium). 0 critical / 0 high remaining.

## [0.1.0] — 2026-04-24

### Added
- **ServiceAgreement contract** rewritten from the ground up with four enforced design properties:
  1. Pull payments via `pendingWithdrawals[token][recipient]` and `withdraw(token)`.
  2. Real timelock on all privileged config changes (arbitrator pool, fee collector, token whitelist).
  3. Solvency invariant: `balance(token) >= totalObligations(token)`. `withdrawSurplus` only takes the strict surplus.
  4. Standard ERC20 only — fee-on-transfer / rebasing tokens rejected at deposit (`FeeOnTransferNotSupported`).
- UUPS upgradeable, OpenZeppelin upgradeable contracts 5.2.
- Templates (`createTemplate`, `updateTemplate`) for reusable terms.
- Ratings system: `submitRating(id, address, score)` with transaction-value-weighted aggregates.
- Pause control on cooperative state changes; pull-payment withdrawals continue even when paused.
- 24-hour client cancellation window with full refund credit.
- Single-arbitrator-pool model with O(1) `isArbitrator(addr)` check.
- Comprehensive view layer (`getAgreementDetails`, `getMilestones`, `getTeam`, `getUserAgreements`, `getUserRating`, `arbitratorPool`, `hasRated`, `pendingWithdrawals`, `totalObligations`).

### Removed
- Dead code from the prior implementation: partial-completion fields, dispute-escalation machinery, milestone-change proposals, per-token slippage settings — all declared but never wired up.
- The previous `emergencyWithdraw` that could drain user-escrowed funds. Replaced with `withdrawSurplus` that can only ever take `balance - obligations`.

### Tooling
- Hardhat CI workflow: tests, coverage, Slither static analysis with `fail-on: low`.
- `solidity-docgen` pipeline; CI verifies generated `docs/api/` is in sync with source NatSpec.
- `slither.config.json` with documented detector suppressions (timestamp comparisons in timelocks, intentional `__gap`, etc.).
- 93 tests across happy paths, adversarial cases, solvency invariants, and the four design properties.

### Documentation
- `docs/scenarios.md`: 8 end-to-end walkthroughs (freelance, audit engagement, team-split, dispute, deadline-miss, cancellation, arbitrator rotation, upgrade).
- `docs/api/index.md`: per-function NatSpec reference (1391 lines).
- `docs/README.md`: integrator landing page.

## [0.0.x] — pre-rewrite

The contract pre-`0.1.0` had several documented security issues that motivated the rewrite. See git history pre-`95bfb87` for the original implementation. Notable issues addressed:

- Owner could `emergencyWithdraw` user-escrowed funds.
- `addWhitelistedToken` immediately whitelisted while *also* scheduling a timelock action — the timelock was theater.
- Provider could DoS milestone payments by including a bad team member that reverts on ETH receive.
- `_handleTokenPayment` slippage check used the *requested* amount, leaving the contract under-funded for fee-on-transfer tokens.
- Rating could be submitted before any milestone was paid.

---

## Security status

This contract has been:

- Subject to two adversarial reviews by an LLM-driven security agent (rounds returned 2 high + 5 medium, then 0 critical/high + 2 medium; all findings addressed).
- Tested with 93 tests at 99% statement / 100% function coverage.
- Run through Slither (0 findings across 78 active detectors).
- Continuously gated on CI: tests, coverage, Slither, doc-sync.

It has **not yet been audited by a professional third party**. Do not deploy to mainnet with real value at stake without one. Track the audit status here; bump to `1.0.0` once an audit signs off.

[Unreleased]: https://github.com/dnakitare/service-agreement/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/dnakitare/service-agreement/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/dnakitare/service-agreement/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/dnakitare/service-agreement/releases/tag/v0.1.0
