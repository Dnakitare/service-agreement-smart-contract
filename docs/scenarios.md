# Scenarios

End-to-end walkthroughs for the most common ways to use `ServiceAgreement`. Each scenario shows the actual on-chain calls in sequence — copy them as a starting point, then adapt addresses, amounts, and milestone schedules.

The examples use `ethers.js` v6. The contract instance is assumed to be at `serviceAgreement` and connected via the proxy address. `client`, `provider`, `arbitrator`, etc. are signers.

For full per-function documentation, see [api/index.md](./api/index.md).

---

## 1. Freelance development engagement (ETH, single party)

**Setup.** A client hires an independent developer for a 3-milestone build, paid in ETH. No team split. No template.

```js
// 1. Client creates the agreement and escrows the full 3 ETH up front.
const oneDay = 24 * 60 * 60;
const t = (await ethers.provider.getBlock("latest")).timestamp;
const dueDates = [t + 7 * oneDay, t + 21 * oneDay, t + 35 * oneDay];
const amounts = [
  ethers.parseEther("1.0"), // M0: design
  ethers.parseEther("1.0"), // M1: implementation
  ethers.parseEther("1.0"), // M2: launch
];
const total = ethers.parseEther("3.0");

const tx = await serviceAgreement.connect(client).createAgreement(
  provider.address,
  "Build a marketing site per spec attached as IPFS QmAbc...",
  dueDates,
  amounts,
  ethers.ZeroAddress,            // ETH
  { value: total }
);
const receipt = await tx.wait();
// Agreement ID is in the AgreementCreated event; for the first agreement, also = agreementCount - 1.
```

**Per-milestone flow.** Provider works on milestone 0, then submits evidence; client approves to release payment. Evidence is typically the IPFS CID of the deliverable (a PR link, design file, etc.). The contract just stores the string.

```js
// 2. Provider submits evidence for milestone 0.
await serviceAgreement.connect(provider)
  .submitMilestoneEvidence(0, 0, "ipfs://QmDesignDeliverable...");

// 3. Client reviews off-chain, then approves to release payment.
//    This single tx marks complete + decrements escrow + credits provider and fee collector.
await serviceAgreement.connect(client).approveMilestone(0, 0);

// 4. Provider claims their funds.
//    They get amount * (1 - PLATFORM_FEE_BPS / 10_000) = 0.99 ETH per milestone.
await serviceAgreement.connect(provider).withdraw(ethers.ZeroAddress);
```

Repeat steps 2–4 for milestones 1 and 2. After approving the final milestone the agreement is automatically marked `completed = true`.

**Rating.** Once completed, both parties can rate each other once, scored 1–5:

```js
// 5. Client rates the provider, provider rates the client.
await serviceAgreement.connect(client).submitRating(0, provider.address, 5);
await serviceAgreement.connect(provider).submitRating(0, client.address, 5);

// Public reputation accessor:
const r = await serviceAgreement.getUserRating(provider.address);
// r.average, r.count, r.weightedAverage (transaction-value-weighted)
```

---

## 2. Smart contract audit engagement (ERC20, single milestone)

**Setup.** A protocol team hires an audit firm. Payment in USDC, single milestone covering the full audit report. Uses an admin-created template for standard audit terms.

**Prereq.** USDC must be whitelisted by the owner. This is itself timelocked:

```js
// (Owner side, executed once during platform setup or via deploy script.)
const data = ethers.AbiCoder.defaultAbiCoder().encode(["address"], [USDC_ADDRESS]);
const sched = await serviceAgreement.connect(owner)
  .scheduleAction(await serviceAgreement.ACTION_WHITELIST_TOKEN(), data);
const actionId = (await sched.wait()).logs
  .map((l) => { try { return serviceAgreement.interface.parseLog(l); } catch { return null; } })
  .find((p) => p?.name === "ActionScheduled").args.actionId;
// ...wait 2 days...
await serviceAgreement.connect(owner).executeAction(actionId);
```

The owner can also create a reusable template:

```js
await serviceAgreement.connect(owner).createTemplate(
  "Smart Contract Audit",
  "Full audit per the standard SoW: scoping call, manual review, automated tools, written report, fix-review pass.",
  21 * oneDay,    // recommended duration
  1               // recommended milestones
);
// returns templateId; assume 0 for the first.
```

**Engagement.**

```js
const usdc = await ethers.getContractAt("IERC20", USDC_ADDRESS);
const fee = ethers.parseUnits("50000", 6); // 50,000 USDC

// 1. Client approves the contract to pull USDC.
await usdc.connect(client).approve(serviceAgreement.target, fee);

// 2. Client creates the agreement from the template.
const t = (await ethers.provider.getBlock("latest")).timestamp;
await serviceAgreement.connect(client).createAgreementFromTemplate(
  0,                       // templateId
  auditFirm.address,
  [t + 21 * oneDay],
  [fee],
  USDC_ADDRESS
);

// 3. Auditor delivers report off-chain, posts the IPFS CID as evidence.
await serviceAgreement.connect(auditFirm)
  .submitMilestoneEvidence(0, 0, "ipfs://QmAuditReport...");

// 4. Client approves; payment is credited.
await serviceAgreement.connect(client).approveMilestone(0, 0);

// 5. Auditor and fee collector each claim their USDC.
await serviceAgreement.connect(auditFirm).withdraw(USDC_ADDRESS);
await serviceAgreement.connect(feeCollector).withdraw(USDC_ADDRESS);
```

> **Important.** Only standard ERC20 tokens work. Fee-on-transfer or rebasing tokens are rejected at deposit (`FeeOnTransferNotSupported`).

---

## 3. Team-split engagement (provider with sub-contractors)

**Setup.** A provider takes a contract but plans to split payment with two sub-contractors. The split is **two-sided**: the provider proposes, the client must approve, otherwise payouts go to the provider as normal.

```js
// 1. Client creates and funds the agreement (as in scenario 1).
const t = (await ethers.provider.getBlock("latest")).timestamp;
await serviceAgreement.connect(client).createAgreement(
  leadDev.address,
  "Build a mobile app: 4 milestones",
  [t + 14 * oneDay, t + 28 * oneDay, t + 42 * oneDay, t + 56 * oneDay],
  [ethers.parseEther("2.5"), ethers.parseEther("2.5"),
   ethers.parseEther("2.5"), ethers.parseEther("2.5")],
  ethers.ZeroAddress,
  { value: ethers.parseEther("10.0") }
);

// 2. Provider proposes a 60/30/10 split.
//    Shares are basis points summing to 10,000.
await serviceAgreement.connect(leadDev).proposeTeam(
  0,
  [leadDev.address, designer.address, qaContractor.address],
  [6000, 3000, 1000]
);

// 3. Client reviews and approves.
//    Until this call, payouts would still go to the provider only.
await serviceAgreement.connect(client).approveTeam(0);

// 4. Subsequent milestone approvals split per the team shares.
//    All three team members withdraw individually.
await serviceAgreement.connect(leadDev).submitMilestoneEvidence(0, 0, "ipfs://Q1");
await serviceAgreement.connect(client).approveMilestone(0, 0);

await serviceAgreement.connect(leadDev).withdraw(ethers.ZeroAddress);
await serviceAgreement.connect(designer).withdraw(ethers.ZeroAddress);
await serviceAgreement.connect(qaContractor).withdraw(ethers.ZeroAddress);
```

**Notes.**

- The provider may re-propose any time **before** the client approves. After approval, the split is locked.
- Rounding dust (from integer division) goes to the **last team member** in the array.
- The team is per-agreement. A different agreement with the same provider needs a new propose/approve.

---

## 4. Disputed engagement, arbitrator splits the difference

**Setup.** A client funds a 2-milestone job. The provider delivers milestone 0 and the client approves. While working on milestone 1, the client decides the work is no longer up to spec and raises a dispute. The arbitrator awards 40% of the remaining escrow to the provider, refunds the rest to the client.

```js
// 1. Client creates and funds the agreement (5 ETH, 2 milestones of 2.5).
//    See scenario 1 for the createAgreement boilerplate.

// 2. Milestone 0 paid out happily.
await serviceAgreement.connect(provider).submitMilestoneEvidence(0, 0, "ipfs://Q0");
await serviceAgreement.connect(client).approveMilestone(0, 0);
await serviceAgreement.connect(provider).withdraw(ethers.ZeroAddress);

// 3. Milestone 1: provider submits evidence, client disputes instead of approving.
await serviceAgreement.connect(provider).submitMilestoneEvidence(0, 1, "ipfs://Q1");
await serviceAgreement.connect(client).raiseDispute(0, "M1 deliverable does not match spec section 4.2");

// 4. Arbitrator (off-chain) reviews evidence and decides on a split.
//    Award the provider 1.0 ETH out of the 2.5 ETH remaining; client gets 1.5 back.
await serviceAgreement.connect(arbitrator).resolveDispute(0, ethers.parseEther("1.0"));

// 5. Both sides claim.
await serviceAgreement.connect(provider).withdraw(ethers.ZeroAddress);
await serviceAgreement.connect(client).withdraw(ethers.ZeroAddress);
```

**The dispute lifecycle, summarized.**

- The **client may dispute at any time** (their funds are at risk).
- The **provider may dispute only after `agreement.deadline`** has elapsed. This prevents them from front-running a client's `approveMilestone` to force arbitration.
- Once disputed, all cooperative writes (`approveMilestone`, `proposeTeam`, `approveTeam`, `submitMilestoneEvidence`, `extendMilestoneDeadline`, `cancelAgreement`) are blocked. The only path out is `resolveDispute`.
- `resolveDispute(amountToProvider)` splits the **remaining escrow** — already-approved milestones are not touched. The platform fee is taken from the provider's share.
- After resolution, both parties can `submitRating` exactly once.

---

## 5. Provider stalls past the deadline

**Setup.** A client funds a job. The provider goes silent and never delivers. After the agreement deadline passes, the provider has the right to dispute (forcing arbitration on whatever they've delivered) — but in practice, the client should dispute first.

```js
// 1. Client creates and funds — final deadline t + 30 days.

// 2. ...time passes, provider unresponsive...

// 3. Client raises dispute.
await serviceAgreement.connect(client).raiseDispute(0, "Provider has not delivered evidence by deadline");

// 4. Arbitrator awards the client the full remaining balance.
await serviceAgreement.connect(arbitrator).resolveDispute(0, 0); // amountToProvider = 0

// 5. Client withdraws.
await serviceAgreement.connect(client).withdraw(ethers.ZeroAddress);
```

**Equivalent outcome via cancellation** is **not** available here because the 24-hour `CANCELLATION_WINDOW` has long since elapsed. Cancellation is a remorse window for the client; deadline-miss is an arbitration matter.

---

## 6. Client cancels within the 24h window

**Setup.** A client funds a job, then immediately changes their mind (wrong spec, wrong provider, etc.). They have 24 hours to cancel as long as no milestone has been approved and no dispute is active.

```js
// 1. Client creates and funds.
await serviceAgreement.connect(client).createAgreement(
  provider.address, "Initial scope", [t + 7 * oneDay], [ethers.parseEther("1")],
  ethers.ZeroAddress, { value: ethers.parseEther("1") }
);

// 2. Within 24h, client cancels.
await serviceAgreement.connect(client).cancelAgreement(0, "Wrong scope, will repost");

// 3. Client withdraws their full refund.
await serviceAgreement.connect(client).withdraw(ethers.ZeroAddress);
```

If the client tries to cancel after **any** milestone has been approved (paid), the call reverts with `AgreementClosed` — the cancellation window covers the unstarted state only.

---

## 7. Operator: rotating arbitrators

**Setup.** Platform owner adds two new arbitrators and removes the original one. Like all privileged config, this is timelocked 2 days.

```js
const newPool = [arbitrator2.address, arbitrator3.address, arbitrator4.address];
const data = ethers.AbiCoder.defaultAbiCoder().encode(["address[]"], [newPool]);

// 1. Schedule.
const tx = await serviceAgreement.connect(owner).scheduleAction(
  await serviceAgreement.ACTION_SET_ARBITRATOR_POOL(), data
);
const actionId = (await tx.wait()).logs
  .map((l) => { try { return serviceAgreement.interface.parseLog(l); } catch { return null; } })
  .find((p) => p?.name === "ActionScheduled").args.actionId;

// 2. ...wait 2 days (TIMELOCK_DELAY)...

// 3. Execute.
await serviceAgreement.connect(owner).executeAction(actionId);
```

The same pattern works for `ACTION_SET_FEE_COLLECTOR`, `ACTION_WHITELIST_TOKEN`, and `ACTION_REMOVE_TOKEN`. Pending actions can be cancelled with `cancelScheduledAction(actionId)`.

---

## 8. Operator: upgrading the implementation

**Setup.** Owner deploys a new implementation and upgrades the proxy. The upgrade itself is timelocked 2 days separately from the config queue.

```js
const ServiceAgreement = await ethers.getContractFactory("ServiceAgreement");

// 1. Deploy the new implementation only (no upgrade yet).
const newImpl = await upgrades.prepareUpgrade(proxyAddr, ServiceAgreement);

// 2. Owner requests the upgrade for that specific implementation address.
await serviceAgreement.connect(owner).requestUpgrade(newImpl);

// 3. ...wait 2 days...

// 4. Perform the actual upgrade.
//    `_authorizeUpgrade` validates that the request exists and the timelock has elapsed.
await upgrades.upgradeProxy(proxyAddr, ServiceAgreement);
```

A pending upgrade request can be cancelled with `cancelUpgradeRequest(impl)`. Each request is for a specific implementation address — re-deploying produces a new address that needs its own request.

---

## Common patterns and gotchas

- **Pull payments**: After `approveMilestone`, `resolveDispute`, or `cancelAgreement`, recipients are *credited*, not paid. They must call `withdraw(token)` themselves. The contract holds the funds in the meantime; the `pendingWithdrawals(token, address)` getter shows what's owed.
- **Token ≠ ETH**: Use `ethers.ZeroAddress` (or `address(0)`) as the `paymentToken` for ETH. For ERC20s, the token must be whitelisted, and the client must `approve(serviceAgreement, total)` before calling `createAgreement*`.
- **Solvency**: For each token, `balance(token) >= totalObligations(token)` is invariant. The owner cannot withdraw escrowed funds. `withdrawSurplus(token, recipient)` only takes the strict surplus from accidental transfers, rebases, or SELFDESTRUCT.
- **No fee-on-transfer**: Whitelist only standard ERC20s. The contract reverts with `FeeOnTransferNotSupported` if `received != amount` on a deposit.
- **Single-tx approve+pay**: Don't try to mark a milestone complete and pay it separately. There is no two-step path; there's just `approveMilestone` (or `batchApproveMilestones`).
- **Rating gates**: Both parties can rate **only after the agreement is `completed`** (final milestone approved or dispute resolved). Each address rates once per agreement.

---

## Event reference

Event listeners pair naturally with the calls above. The minimum set most integrators want:

| Event | When |
|---|---|
| `AgreementCreated(id, client, provider, totalAmount, milestoneCount, paymentToken, terms)` | After `createAgreement*` succeeds. |
| `MilestoneEvidenceSubmitted(id, milestoneIndex, evidenceHash)` | Provider posted evidence. |
| `MilestoneApproved(id, milestoneIndex, amount, fee)` | Client approved + paid. |
| `BatchMilestonesApproved(id, indices, totalAmount, totalFee)` | Same, for `batchApproveMilestones`. |
| `TeamProposed(id, members, shares)` | Provider proposed a split. |
| `TeamApproved(id)` | Client locked the split in. |
| `DisputeRaised(id, initiator, reason)` / `DisputeResolved(id, amountToProvider, amountToClient)` | Dispute lifecycle. |
| `AgreementCancelled(id, initiator, reason)` | 24h cancel window used. |
| `RatingSubmitted(id, rater, rated, score)` | Post-completion rating. |
| `Withdrawn(token, recipient, amount)` | Pull payment claimed. |
