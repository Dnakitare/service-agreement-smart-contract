---
title: Errors
nav_order: 3
---

# Errors reference

Every revert from `ServiceAgreement` is a typed custom error. This page maps each error to (a) the function(s) that throw it, (b) the cause as the integrator usually sees it, and (c) what to do about it.

When decoding reverts in ethers v6 / viem, the error name and arguments come back from the contract's ABI. With `safeContractCall(...)` patterns or `.then().catch()` you can dispatch on `error.errorName`.

```ts
try {
  await serviceAgreement.approveMilestone(id, idx);
} catch (e: any) {
  if (e?.errorName === "EvidenceMissing") {
    // surface a "ask the provider to submit evidence first" UI
  } else if (e?.errorName === "AgreementClosed") {
    // refresh state — the agreement was disputed, cancelled, or completed
  }
}
```

---

## Authorization

| Error | Where | Cause | Handling |
|---|---|---|---|
| `Unauthorized` | Most state-changing functions | `msg.sender` is not the role required (client / provider / participant / arbitrator). | Surface "wrong account" UI. Verify the connected wallet matches the role you're rendering. |
| `ZeroAddress` | `initialize`, `requestUpgrade`, `_setFeeCollector`, `_setTokenWhitelist`, `proposeTeam`, `withdrawSurplus` | `address(0)` passed where a real address is required. | Pre-validate inputs in the UI; never let a user submit `0x000...0`. |
| `InvalidProvider` | `createAgreement*` | `provider == address(0)` or `provider == msg.sender`. | The client cannot also be the provider. UI should disallow self-selection. |

## Agreement state machine

| Error | Where | Cause | Handling |
|---|---|---|---|
| `AgreementNotFound` | All `validAgreement(id)` modifier paths | `agreementId >= agreementCount` (id never existed). | Re-fetch `agreementCount` and reconcile your local list. |
| `AgreementClosed` | Most write functions on an agreement | The agreement is `cancelled` or `completed`, **or** disputed (when called from a `notDisputed` path). | Refresh agreement state. The agreement is no longer mutable — show its terminal state. |
| `AgreementNotDisputed` | `resolveDispute` | The agreement isn't currently in a disputed state. | Only call `resolveDispute` after a successful `raiseDispute`. Listen to `DisputeRaised`. |
| `AgreementNotComplete` | `submitRating` | Tried to rate before the agreement is `completed`. | Gate the rating UI on `getAgreementDetails(id).completed === true`. |
| `DisputeAlreadyRaised` | `raiseDispute` | A dispute is already pending. | Re-fetch state; a dispute is in flight. |
| `NoDisputeGrounds` | `raiseDispute` | Provider is trying to dispute before `agreement.deadline`. | Only show "Raise dispute" to the provider once `block.timestamp > agreement.deadline`. The client can dispute any time. |
| `CancellationWindowExpired` | `cancelAgreement` | Client tried to cancel after the 24-hour window. | Hide "Cancel" once `block.timestamp > createdAt + CANCELLATION_WINDOW`. |

## Milestones

| Error | Where | Cause | Handling |
|---|---|---|---|
| `MilestoneIndexOutOfBounds` | `submitMilestoneEvidence`, `approveMilestone`, `batchApproveMilestones`, `extendMilestoneDeadline`, `getMilestone` | Index `>= milestones.length`. | Validate index against `getMilestoneCount(id)`. |
| `MilestoneAlreadyPaid` | `approveMilestone`, `batchApproveMilestones`, `extendMilestoneDeadline`, `submitMilestoneEvidence` | The milestone has already been paid out. With the merged approve+pay design, this also means it's already complete. | Re-fetch state; the milestone is finalized. |
| `EvidenceMissing` | `approveMilestone`, `batchApproveMilestones` | Client tried to approve before the provider submitted evidence. | Show "Awaiting provider evidence" until `getMilestone(id, idx).evidenceHash !== ""`. |
| `EvidenceCommitmentMismatch` | `approveMilestone`, `batchApproveMilestones` | The client passed `expectedEvidenceHash != bytes32(0)` and the on-chain evidence's keccak doesn't match. Typical cause: the provider front-ran with `submitMilestoneEvidence` to swap the evidence between the client's review and tx mining. | Treat as adversarial — re-fetch the evidence, surface a "evidence changed since review" warning, and require explicit re-confirmation from the user. |
| `EvidenceEmpty` | `submitMilestoneEvidence` | Provider passed an empty string. | Validate the hash on the client side before sending the tx. |
| `MilestonesNotChronological` | `_createAgreement` | Milestone deadlines are not strictly increasing. | Sort or validate at form time. |
| `TooManyMilestones` | `createTemplate`, `updateTemplate`, `_createAgreement` (via `InvalidArrayLength`) | More than `MAX_MILESTONES` (20) milestones. | Cap the form at 20. |

## Team payments

| Error | Where | Cause | Handling |
|---|---|---|---|
| `TeamAlreadySet` | `proposeTeam`, `approveTeam` | Team has been approved (locked). | After the client approves, neither side can change the split — surface this as terminal. |
| `NoTeamProposed` | `approveTeam` | Client tried to approve, but the provider hasn't proposed a team. | Hide "Approve team" until you observe `TeamProposed` for this agreement. |
| `NoTeamMembers` | `proposeTeam` | Empty `members` array. | Form validation. |
| `TooManyTeamMembers` | `proposeTeam` | More than `MAX_TEAM_MEMBERS` (10). | Cap the form. |
| `InvalidShares` | `proposeTeam` | Shares contain a zero, or do not sum to `BASIS_POINTS` (10,000). | Validate on the client; show the running sum to the user as they edit. |

## Validation

| Error | Where | Cause | Handling |
|---|---|---|---|
| `InvalidArrayLength` | `_createAgreement`, `batchApproveMilestones`, `_setArbitratorPool` | Array length is 0 or out of bounds. | Form validation. |
| `ArrayLengthMismatch` | `_createAgreement`, `proposeTeam` | `dueDates.length != amounts.length`, or `members.length != shares.length`. | Form invariants. |
| `InvalidDeadline` | `_createAgreement`, `extendMilestoneDeadline`, `executeAction` | A timestamp comparison failed: first deadline ≤ now, extension ≤ existing deadline, etc. | Recompute deadlines from `block.timestamp` at submit time, not page load. |
| `InvalidRating` | `submitRating` | Score not in `[1, 5]`. | UI: bound the input. |
| `InvalidShares` | `proposeTeam` | Shares zero or don't sum to 10,000 BPS. | See team payments above. |
| `DurationTooLong` | `_createAgreement`, `extendMilestoneDeadline`, `createTemplate`, `updateTemplate` | Final deadline > `block.timestamp + MAX_DEADLINE` (365 days). | Cap the form. |
| `WrongPaymentAmount` | `_createAgreement` | One of: `msg.value != totalAmount` for ETH; a milestone has 0 amount; total is 0; total > `uint128.max`. | Recompute total in the form before submit. |
| `InsufficientFunds` | `resolveDispute` | `amountToProvider > remainingAmount`. | Constrain the arbitrator's input to ≤ `getAgreementDetails(id).remainingAmount`. |
| `CannotRateSelf` | `submitRating` | `ratedAddress == msg.sender`. | UI: don't show your own address as a rating target. |
| `AlreadyRated` | `submitRating` | This address has already rated this agreement. | Check `hasRated(id, msg.sender)` before showing the form. |

## Tokens / payment

| Error | Where | Cause | Handling |
|---|---|---|---|
| `TokenNotWhitelisted` | `_createAgreement` | The selected ERC20 isn't whitelisted. | Drive the token picker from `whitelistedTokens(addr)` reads or from `TokenWhitelisted` events. |
| `EthNotAcceptedForToken` | `_createAgreement` | Sent `msg.value > 0` while specifying an ERC20. | UI: only attach `value` when `paymentToken === ZeroAddress`. |
| `FeeOnTransferNotSupported` | `_pullToken` (during `_createAgreement`) | The token charged a fee on `transferFrom`, so `received != amount`. | Don't whitelist fee-on-transfer or rebasing tokens. If a token suddenly starts behaving this way, remove it from the whitelist. |
| `NothingToWithdraw` | `withdraw`, `withdrawSurplus` | The recipient has zero pending balance, or surplus is zero. | Read `pendingWithdrawals(token, user)` first to gate the button. |
| `TransferFailed` | `withdraw`, `withdrawSurplus` | An ETH `.call` returned `false`. | Recipient is a contract that refuses ETH; have them set a different recipient. With pull payments this only affects the recipient calling `withdraw`. |

## Timelock / upgrades / templates

| Error | Where | Cause | Handling |
|---|---|---|---|
| `InvalidActionType` | `scheduleAction`, `executeAction` (defensive) | `actionType` is not one of the four `ACTION_*` constants. | Use the contract's exposed constants. |
| `ActionAlreadyScheduled` | `scheduleAction` | Same `(actionType, data)` scheduled twice in the same block. | Avoid duplicate scheduling in multicalls; use distinct payloads or different blocks. |
| `ActionAlreadyExecuted` | `executeAction`, `cancelScheduledAction` | The action was already executed once. | Refresh state; you've already applied this change. |
| `ActionNotFound` | `executeAction`, `cancelScheduledAction`, `cancelUpgradeRequest` | No pending action with this ID. | Check the `ActionScheduled` event you have stored. |
| `TimelockNotElapsed` | `executeAction`, `_authorizeUpgrade` | Tried to execute before `executableAt`. | Read the `ActionScheduled` event's `executableAt` and gate the UI. |
| `UpgradeNotRequested` | `_authorizeUpgrade` | Tried `upgradeToAndCall` without a prior `requestUpgrade(impl)`. | Always call `requestUpgrade` first; wait the timelock; then upgrade. |
| `TemplateNotFound` | `updateTemplate`, `createAgreementFromTemplate` | `templateId >= templateCount`. | Drive the dropdown from `templateCount`. |
| `TemplateNotActive` | `createAgreementFromTemplate` | The template's `active` flag is false. | Hide inactive templates in the picker. |
| `TooManyArbitrators` | `_setArbitratorPool` | New pool > `MAX_ARBITRATORS` (10). | Cap admin inputs. |
| `ArbitratorIsParticipant` | `resolveDispute` | The arbitrator calling `resolveDispute` is also the client or provider of this specific agreement. | Have a different arbitrator from the pool resolve. |

---

## Patterns

**Decoding revert reasons.** ethers v6 surfaces custom errors as `error.errorName` and `error.errorArgs`. The contract's TypeChain typings encode the ABI so `errorName` is well-defined for any revert from this contract.

**Don't show technical names to end users.** Map each error to a human-friendly message in your UI. The table above gives you the suggested copy.

**Defensive errors.** A few errors exist as defense-in-depth and are not reachable through the public API in the current implementation: `InvalidActionType` inside `executeAction` (already validated by `scheduleAction`), the `n == 0` branch of team distribution. They can still appear if the contract is upgraded; treat them as bugs in the implementation, not user errors.

**Pre-flight reads.** Many error states can be detected without sending a transaction. Before calling:

| Action | Read first |
|---|---|
| `approveMilestone` | `getMilestone(id, idx).evidenceHash`, `paid`, `getAgreementDetails(id).disputed` |
| `cancelAgreement` | `createdAt + CANCELLATION_WINDOW > now`, no milestone paid, not disputed |
| `raiseDispute` (provider) | `block.timestamp > getAgreementDetails(id).deadline` |
| `withdraw` | `pendingWithdrawals(token, msg.sender) > 0` |
| `submitRating` | `getAgreementDetails(id).completed`, `!hasRated(id, msg.sender)` |
| `approveTeam` | `getTeam(id).members.length > 0`, agreement not disputed |
| `executeAction` | `block.timestamp >= action.executableAt` |
| `_authorizeUpgrade` (via `upgradeToAndCall`) | `upgradeRequestedAt(impl) > 0`, `block.timestamp >= upgradeRequestedAt(impl)` |

Doing these reads in your indexer or page-load lets you preempt almost every revert before the user signs.
