# ServiceAgreement

A milestone-based escrow contract for service agreements between a client and a provider, written in Solidity 0.8.28 and deployed behind a UUPS proxy.

## What it does

A client funds an agreement up front (in ETH or a whitelisted ERC20). The funds are escrowed milestone-by-milestone. The provider submits evidence for each milestone; the client signs off; payment is then claimable by the provider. A platform fee (default 1%) is taken at release time and credited to the fee collector.

If the parties disagree, either may raise a dispute. An arbitrator from the configured pool resolves it by deciding how much of the *remaining* escrow goes to the provider; the rest is refunded to the client.

The provider may optionally split payments across a team (up to 10 members) by basis-point shares.

## Design properties

The contract is built around six properties that the test suite enforces:

1. **Pull payments** — `approveMilestone`, `resolveDispute`, `cancelAgreement` and `proposeTeam` never push ETH or tokens. They credit `pendingWithdrawals[token][recipient]`. Recipients call `withdraw(token)` to claim. A single bad recipient (e.g. a contract that reverts on ETH receive) cannot block any other recipient.

2. **Real timelock on config + upgrades** — every privileged config change (rotating the arbitrator pool, changing the fee collector, whitelisting/removing a token) and every implementation upgrade goes through a 2-day delay. There is no immediate-execute bypass. A compromised owner key cannot rug funds within the timelock window.

3. **Solvency invariant** — for every accepted token, the contract maintains `balance(token) >= totalObligations[token]` at all times. `withdrawSurplus` can only ever transfer the strict surplus above obligations.

4. **No fee-on-transfer / rebasing tokens** — `_pullToken` checks that the contract received exactly the requested amount and reverts with `FeeOnTransferNotSupported` otherwise.

5. **Atomic milestone approve + pay** — there is no separate "mark complete" step. `approveMilestone` simultaneously marks the milestone complete, decrements escrow, and credits the recipients. This eliminates the front-running window where a malicious provider could `raiseDispute` between the client's `completeMilestone` and `releaseMilestonePayment` calls. It also closes the cancel-after-completion grift where a client could mark work complete then cancel within the 24h window.

6. **Two-sided team payment authorization** — the provider may `proposeTeam(members, shares)` but no payouts are split until the client calls `approveTeam`. A malicious provider therefore cannot redirect funds the client has already escrowed.

## Lifecycle

```
client funds agreement ─> provider.submitMilestoneEvidence ─> client.approveMilestone
                                                                        │
                                            credits pendingWithdrawals[token][provider]
                                            credits pendingWithdrawals[token][feeCollector]
                                                                        │
                                            provider.withdraw / feeCollector.withdraw
```

`approveMilestone` is a single atomic step that marks the milestone complete, decrements escrow, and credits the recipients. `batchApproveMilestones` does the same for many milestones in one call.

**Disputes.** The client may call `raiseDispute` at any time. The provider may only call `raiseDispute` after the agreement deadline has passed — this prevents the provider from front-running a release tx to force arbitration. The arbitrator then calls `resolveDispute(agreementId, amountToProvider)` to split the remaining escrow; the rest is refunded to the client.

**Cancellation.** The client may `cancelAgreement` within 24 hours of creation, but only if no milestone has been paid and no dispute is active. The full remaining balance is credited back to the client.

**Team payments.** The provider may `proposeTeam(members, shares)` (basis points summing to 10,000, max 10 members). The client must then `approveTeam` for the split to take effect; until approved, payouts go to the provider. The provider may re-propose to overwrite the previous proposal up until approval. After approval, the split is locked.

**Upgrades.** The owner calls `requestUpgrade(newImplementation)`, waits 2 days, then calls `upgradeToAndCall`. `_authorizeUpgrade` validates that the implementation matches a request whose timelock has elapsed; otherwise it reverts. Upgrade requests can be cancelled.

## Documentation

- **[docs/scenarios.md](./docs/scenarios.md)** — end-to-end walkthroughs for common flows (freelance, audit engagement, team split, disputes, cancellations, operator rotations, upgrades).
- **[docs/api/index.md](./docs/api/index.md)** — per-function API reference generated from NatSpec via `npm run docs`.
- **[docs/README.md](./docs/README.md)** — docs landing page.

## Layout

```
contracts/
  ServiceAgreement.sol        # the contract
  test/
    MockERC20.sol             # standard ERC20 for tests
    MockTokenWithFee.sol      # fee-on-transfer token (used to verify rejection)
    EthRefuser.sol            # contract that refuses ETH; verifies pull-payment isolation
docs/
  README.md                   # docs landing
  scenarios.md                # end-to-end walkthroughs
  api/index.md                # generated API reference
scripts/
  deploy.js                   # deploys proxy + schedules privileged config
  upgrade.js                  # upgrades the implementation behind the proxy
  verify.js                   # Etherscan verification helper
test/
  ServiceAgreement.test.js    # 93 tests: happy paths + adversarial cases
hardhat.config.js
slither.config.json
```

## Develop

```bash
npm install
npm run compile
npm test
```

## Deploy

Set the addresses you want to use, then run the deploy script. The script schedules timelocked actions; you must call `executeAction(actionId)` for each after `TIMELOCK_DELAY` (2 days) has elapsed.

```bash
ARBITRATOR=0x... \
FEE_COLLECTOR=0x... \
ARBITRATOR_POOL=0x...,0x... \
WHITELIST_TOKENS=0x... \
npx hardhat run scripts/deploy.js --network sepolia
```

To upgrade an existing proxy:

```bash
PROXY_ADDRESS=0x... npx hardhat run scripts/upgrade.js --network sepolia
```

## Continuous integration

GitHub Actions (`.github/workflows/ci.yml`) runs on every push and PR:

- `npm test` (Hardhat test suite)
- `npm run coverage` (solidity-coverage; report uploaded as artifact)
- Slither static analysis via `crytic/slither-action`, with `fail-on: low`

The slither config (`slither.config.json`) suppresses these detectors as documented false positives:

| Detector | Reason for suppression |
|---|---|
| `timestamp` | All `block.timestamp` comparisons here are intentional (timelocks, deadlines, cancellation window). Modern PoS bounds drift to a few seconds; not exploitable for the scales used. |
| `uninitialized-local` | Solidity 0.8 zero-initializes uints. Style-only. |
| `cyclomatic-complexity` | `_createAgreement` performs validation that's a single logical step but counts as many branches. |
| `unused-state` | `__gap` is intentionally unused — that is its purpose for upgradeability. |
| `naming-convention`, `solc-version`, `similar-names` | Style-only. |

Any *new* slither finding (any severity ≥ low not in the suppression list) fails CI.

## Operational notes

- Whitelist only standard ERC20 tokens. Rebasing tokens, fee-on-transfer tokens, and tokens with non-standard `transfer` semantics are not supported and will revert at deposit time.
- The owner key controls the timelock queue and the upgrade path. Use a multisig for production.
- The arbitrator pool is the only role authorized to resolve disputes. Pool rotations are themselves timelocked.
- `withdrawSurplus` is for accidental transfers — never for escrowed funds. The contract's solvency invariant guarantees it can never decrement obligations.

## License

MIT
