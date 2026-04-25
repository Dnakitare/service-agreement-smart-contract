# ServiceAgreement

A milestone-based escrow contract for service agreements between a client and a provider, written in Solidity 0.8.28 and deployed behind a UUPS proxy.

## What it does

A client funds an agreement up front (in ETH or a whitelisted ERC20). The funds are escrowed milestone-by-milestone. The provider submits evidence for each milestone; the client signs off; payment is then claimable by the provider. A platform fee (default 1%) is taken at release time and credited to the fee collector.

If the parties disagree, either may raise a dispute. An arbitrator from the configured pool resolves it by deciding how much of the *remaining* escrow goes to the provider; the rest is refunded to the client.

The provider may optionally split payments across a team (up to 10 members) by basis-point shares.

## Design properties

The contract is built around four properties that the test suite enforces:

1. **Pull payments** — `releaseMilestonePayment`, `resolveDispute`, `cancelAgreement` and `addTeamMembers` never push ETH or tokens. They credit `pendingWithdrawals[token][recipient]`. Recipients call `withdraw(token)` to claim. A single bad recipient (e.g. a contract that reverts on ETH receive) cannot block any other recipient.

2. **Real timelock** — every privileged config change (rotating the arbitrator pool, changing the fee collector, whitelisting/removing a token) goes through `scheduleAction → executeAction` with a 2-day delay. There is no immediate-execute bypass. The owner cannot whitelist a token and use it in the same block.

3. **Solvency invariant** — for every accepted token, the contract maintains `balance(token) >= totalObligations[token]` at all times. `withdrawSurplus` can only ever transfer the strict surplus above obligations. There is no `emergencyWithdraw` that drains escrow.

4. **No fee-on-transfer / rebasing tokens** — `_pullToken` checks that the contract received exactly the requested amount and reverts with `FeeOnTransferNotSupported` otherwise. This keeps the solvency invariant exact and reflects the assumption that whitelisted tokens are standard ERC20s.

## Lifecycle

```
                          ┌─ submitMilestoneEvidence ──┐
client funds agreement ──>│                            ├──> client.completeMilestone
                          └────────────────────────────┘            │
                                                                    ▼
                                                      client.releaseMilestonePayment
                                                                    │
                                            credits pendingWithdrawals[token][provider]
                                            credits pendingWithdrawals[token][feeCollector]
                                                                    │
                                          provider.withdraw(token), feeCollector.withdraw(token)
```

Either party may call `raiseDispute` at any time before the agreement is completed or cancelled. The arbitrator then calls `resolveDispute(agreementId, amountToProvider)` to split the remaining escrow.

The client may `cancelAgreement` within 24 hours of creation, but only if no milestone has been paid and no dispute is active. The full remaining balance is credited back to the client.

## Layout

```
contracts/
  ServiceAgreement.sol        # the contract
  test/
    MockERC20.sol             # standard ERC20 for tests
    MockTokenWithFee.sol      # fee-on-transfer token (used to verify rejection)
    EthRefuser.sol            # contract that refuses ETH; verifies pull-payment isolation
scripts/
  deploy.js                   # deploys proxy + schedules privileged config
  upgrade.js                  # upgrades the implementation behind the proxy
  verify.js                   # Etherscan verification helper
test/
  ServiceAgreement.test.js    # 61 tests: happy paths + adversarial cases
hardhat.config.js
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

## Operational notes

- Whitelist only standard ERC20 tokens. Rebasing tokens, fee-on-transfer tokens, and tokens with non-standard `transfer` semantics are not supported and will revert at deposit time.
- The owner key controls the timelock queue and the upgrade path. Use a multisig for production.
- The arbitrator pool is the only role authorized to resolve disputes. Pool rotations are themselves timelocked.
- `withdrawSurplus` is for accidental transfers — never for escrowed funds. The contract's solvency invariant guarantees it can never decrement obligations.

## License

MIT
