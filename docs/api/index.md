---
title: API reference
nav_order: 4
---

# Solidity API

## ServiceAgreement

Milestone-based escrow for service agreements between a client and a provider.
The client funds an agreement up front; the provider submits evidence per milestone;
the client approves to release payment. A platform fee (default 1%) is taken at
release. Disputes are resolved by an arbitrator from a configured pool.

_Six enforced design properties:

1. **Pull payments.** All payouts credit `pendingWithdrawals[token][recipient]`.
   Recipients claim with `withdraw(token)`. A refusing receiver only affects itself.

2. **Real timelock on config + upgrades.** Every privileged config change and every
   implementation upgrade goes through `scheduleAction → executeAction` (or
   `requestUpgrade → upgradeToAndCall`) with a 2-day delay. No immediate bypass.

3. **Solvency.** For every token, `balance(token) >= totalObligations[token]` at
   all times. `withdrawSurplus` can only ever take the strict surplus.

4. **Standard ERC20 only.** `_pullToken` reverts if `received != amount`,
   rejecting fee-on-transfer and rebasing tokens.

5. **Atomic milestone approve + pay.** `approveMilestone` marks the milestone
   complete, decrements escrow, and credits the recipients in one transaction.
   There is no separate "complete" step — eliminating the front-run window where
   a malicious provider could `raiseDispute` between completion and payment.

6. **Two-sided team payment authorization.** `proposeTeam` (provider) +
   `approveTeam` (client). Until the client approves, payouts go to the provider._

### ZeroAddress

```solidity
error ZeroAddress()
```

### InvalidProvider

```solidity
error InvalidProvider()
```

### InvalidArrayLength

```solidity
error InvalidArrayLength()
```

### ArrayLengthMismatch

```solidity
error ArrayLengthMismatch()
```

### InvalidDeadline

```solidity
error InvalidDeadline()
```

### InvalidRating

```solidity
error InvalidRating()
```

### InvalidShares

```solidity
error InvalidShares()
```

### Unauthorized

```solidity
error Unauthorized()
```

### AgreementNotFound

```solidity
error AgreementNotFound()
```

### AgreementClosed

```solidity
error AgreementClosed()
```

### AgreementNotDisputed

```solidity
error AgreementNotDisputed()
```

### AgreementNotComplete

```solidity
error AgreementNotComplete()
```

### DisputeAlreadyRaised

```solidity
error DisputeAlreadyRaised()
```

### MilestoneIndexOutOfBounds

```solidity
error MilestoneIndexOutOfBounds()
```

### MilestoneAlreadyPaid

```solidity
error MilestoneAlreadyPaid()
```

### EvidenceMissing

```solidity
error EvidenceMissing()
```

### EvidenceEmpty

```solidity
error EvidenceEmpty()
```

### MilestonesNotChronological

```solidity
error MilestonesNotChronological()
```

### TooManyMilestones

```solidity
error TooManyMilestones()
```

### TooManyTeamMembers

```solidity
error TooManyTeamMembers()
```

### NoTeamMembers

```solidity
error NoTeamMembers()
```

### TeamAlreadySet

```solidity
error TeamAlreadySet()
```

### AlreadyRated

```solidity
error AlreadyRated()
```

### CannotRateSelf

```solidity
error CannotRateSelf()
```

### TokenNotWhitelisted

```solidity
error TokenNotWhitelisted()
```

### WrongPaymentAmount

```solidity
error WrongPaymentAmount()
```

### EthNotAcceptedForToken

```solidity
error EthNotAcceptedForToken()
```

### FeeOnTransferNotSupported

```solidity
error FeeOnTransferNotSupported()
```

### TemplateNotFound

```solidity
error TemplateNotFound()
```

### TemplateNotActive

```solidity
error TemplateNotActive()
```

### DurationTooLong

```solidity
error DurationTooLong()
```

### CancellationWindowExpired

```solidity
error CancellationWindowExpired()
```

### TimelockNotElapsed

```solidity
error TimelockNotElapsed()
```

### ActionAlreadyExecuted

```solidity
error ActionAlreadyExecuted()
```

### ActionNotFound

```solidity
error ActionNotFound()
```

### NothingToWithdraw

```solidity
error NothingToWithdraw()
```

### TransferFailed

```solidity
error TransferFailed()
```

### InsufficientFunds

```solidity
error InsufficientFunds()
```

### InvalidActionType

```solidity
error InvalidActionType()
```

### NoTeamProposed

```solidity
error NoTeamProposed()
```

### TeamNotApproved

```solidity
error TeamNotApproved()
```

### NoDisputeGrounds

```solidity
error NoDisputeGrounds()
```

### UpgradeNotRequested

```solidity
error UpgradeNotRequested()
```

### ActionAlreadyScheduled

```solidity
error ActionAlreadyScheduled()
```

### TooManyArbitrators

```solidity
error TooManyArbitrators()
```

### MAX_MILESTONES

```solidity
uint256 MAX_MILESTONES
```

### MAX_DEADLINE

```solidity
uint256 MAX_DEADLINE
```

### PLATFORM_FEE_BPS

```solidity
uint256 PLATFORM_FEE_BPS
```

### BASIS_POINTS

```solidity
uint256 BASIS_POINTS
```

### MIN_RATING

```solidity
uint256 MIN_RATING
```

### MAX_RATING

```solidity
uint256 MAX_RATING
```

### CANCELLATION_WINDOW

```solidity
uint256 CANCELLATION_WINDOW
```

### TIMELOCK_DELAY

```solidity
uint256 TIMELOCK_DELAY
```

### MAX_TEAM_MEMBERS

```solidity
uint256 MAX_TEAM_MEMBERS
```

### MAX_ARBITRATORS

```solidity
uint256 MAX_ARBITRATORS
```

### ACTION_SET_ARBITRATOR_POOL

```solidity
bytes32 ACTION_SET_ARBITRATOR_POOL
```

### ACTION_SET_FEE_COLLECTOR

```solidity
bytes32 ACTION_SET_FEE_COLLECTOR
```

### ACTION_WHITELIST_TOKEN

```solidity
bytes32 ACTION_WHITELIST_TOKEN
```

### ACTION_REMOVE_TOKEN

```solidity
bytes32 ACTION_REMOVE_TOKEN
```

### ETH

```solidity
address ETH
```

### Milestone

```solidity
struct Milestone {
  uint64 deadline;
  uint128 amount;
  bool completed;
  bool paid;
  string evidenceHash;
}
```

### Agreement

```solidity
struct Agreement {
  address client;
  address provider;
  uint128 totalAmount;
  uint128 remainingAmount;
  uint64 deadline;
  uint64 createdAt;
  bool completed;
  bool disputed;
  bool cancelled;
  bool teamApproved;
  address paymentToken;
  string terms;
  struct ServiceAgreement.Milestone[] milestones;
  address[] teamMembers;
  uint256[] teamShares;
  mapping(address => bool) hasRated;
}
```

### Template

```solidity
struct Template {
  string name;
  string terms;
  uint256 recommendedDuration;
  uint256 recommendedMilestones;
  bool active;
}
```

### Rating

```solidity
struct Rating {
  uint256 total;
  uint256 count;
  uint256 weightedScore;
  uint256 totalTransactionValue;
}
```

### PendingAction

```solidity
struct PendingAction {
  bytes32 actionType;
  bytes data;
  uint256 executableAt;
  bool executed;
}
```

### agreementCount

```solidity
uint256 agreementCount
```

### templateCount

```solidity
uint256 templateCount
```

### templates

```solidity
mapping(uint256 => struct ServiceAgreement.Template) templates
```

### ratings

```solidity
mapping(address => struct ServiceAgreement.Rating) ratings
```

### whitelistedTokens

```solidity
mapping(address => bool) whitelistedTokens
```

### feeCollector

```solidity
address feeCollector
```

### isArbitrator

```solidity
mapping(address => bool) isArbitrator
```

### pendingActions

```solidity
mapping(bytes32 => struct ServiceAgreement.PendingAction) pendingActions
```

### pendingWithdrawals

```solidity
mapping(address => mapping(address => uint256)) pendingWithdrawals
```

### totalObligations

```solidity
mapping(address => uint256) totalObligations
```

### upgradeRequestedAt

```solidity
mapping(address => uint256) upgradeRequestedAt
```

### AgreementCreated

```solidity
event AgreementCreated(uint256 agreementId, address client, address provider, uint256 totalAmount, uint256 milestoneCount, address paymentToken, string terms)
```

### MilestoneEvidenceSubmitted

```solidity
event MilestoneEvidenceSubmitted(uint256 agreementId, uint256 milestoneIndex, string evidenceHash)
```

### MilestoneApproved

```solidity
event MilestoneApproved(uint256 agreementId, uint256 milestoneIndex, uint256 amount, uint256 fee)
```

### BatchMilestonesApproved

```solidity
event BatchMilestonesApproved(uint256 agreementId, uint256[] milestoneIndices, uint256 totalAmount, uint256 totalFee)
```

### MilestoneDeadlineExtended

```solidity
event MilestoneDeadlineExtended(uint256 agreementId, uint256 milestoneIndex, uint256 newDeadline)
```

### AgreementCancelled

```solidity
event AgreementCancelled(uint256 agreementId, address initiator, string reason)
```

### DisputeRaised

```solidity
event DisputeRaised(uint256 agreementId, address initiator, string reason)
```

### DisputeResolved

```solidity
event DisputeResolved(uint256 agreementId, uint256 amountToProvider, uint256 amountToClient)
```

### RatingSubmitted

```solidity
event RatingSubmitted(uint256 agreementId, address rater, address rated, uint256 score)
```

### TeamProposed

```solidity
event TeamProposed(uint256 agreementId, address[] members, uint256[] shares)
```

### TeamApproved

```solidity
event TeamApproved(uint256 agreementId)
```

### TemplateCreated

```solidity
event TemplateCreated(uint256 templateId, string name)
```

### TemplateUpdated

```solidity
event TemplateUpdated(uint256 templateId, string name, bool active)
```

### TokenWhitelisted

```solidity
event TokenWhitelisted(address token, bool status)
```

### ArbitratorPoolUpdated

```solidity
event ArbitratorPoolUpdated(address[] arbitrators)
```

### FeeCollectorUpdated

```solidity
event FeeCollectorUpdated(address oldCollector, address newCollector)
```

### ActionScheduled

```solidity
event ActionScheduled(bytes32 actionId, bytes32 actionType, bytes data, uint256 executableAt)
```

### ActionExecuted

```solidity
event ActionExecuted(bytes32 actionId)
```

### ActionCancelled

```solidity
event ActionCancelled(bytes32 actionId)
```

### Withdrawn

```solidity
event Withdrawn(address token, address recipient, uint256 amount)
```

### SurplusWithdrawn

```solidity
event SurplusWithdrawn(address token, address recipient, uint256 amount)
```

### UpgradeRequested

```solidity
event UpgradeRequested(address newImplementation, uint256 executableAt)
```

### UpgradeRequestCancelled

```solidity
event UpgradeRequestCancelled(address newImplementation)
```

### ContractUpgraded

```solidity
event ContractUpgraded(address newImplementation)
```

### onlyClient

```solidity
modifier onlyClient(uint256 agreementId)
```

### onlyProvider

```solidity
modifier onlyProvider(uint256 agreementId)
```

### onlyParticipant

```solidity
modifier onlyParticipant(uint256 agreementId)
```

### onlyArbitrator

```solidity
modifier onlyArbitrator()
```

### validAgreement

```solidity
modifier validAgreement(uint256 agreementId)
```

### active

```solidity
modifier active(uint256 agreementId)
```

### notDisputed

```solidity
modifier notDisputed(uint256 agreementId)
```

_Used to freeze cooperative state changes (team proposals, evidence,
deadline edits) once a dispute is raised. Resolution is the only path
out from a disputed state._

### constructor

```solidity
constructor() public
```

### initialize

```solidity
function initialize(address arbitrator_, address feeCollector_) external
```

Initializes the proxy. Called once at deployment via the UUPS proxy.
The caller becomes `owner`. Seeds the arbitrator pool with a single arbitrator;
rotate later via the timelocked `scheduleAction(ACTION_SET_ARBITRATOR_POOL)`.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| arbitrator_ | address | Initial arbitrator. Must be non-zero. |
| feeCollector_ | address | Address that receives the platform fee on each payout. Must be non-zero. |

### requestUpgrade

```solidity
function requestUpgrade(address newImplementation) external
```

Schedules an upgrade to `newImplementation`. The upgrade itself (via
`upgradeToAndCall`) only succeeds after `TIMELOCK_DELAY` has elapsed. Calling
again for the same implementation overwrites the executable time, effectively
resetting (or extending) the timelock for that target.

_`_authorizeUpgrade` consumes the request on success._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newImplementation | address | Address of the new implementation contract. Must be non-zero. |

### cancelUpgradeRequest

```solidity
function cancelUpgradeRequest(address newImplementation) external
```

Cancels a previously-scheduled upgrade request.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newImplementation | address | Implementation address whose request should be cancelled. |

### _authorizeUpgrade

```solidity
function _authorizeUpgrade(address newImplementation) internal
```

_Function that should revert when `msg.sender` is not authorized to upgrade the contract. Called by
{upgradeToAndCall}.

Normally, this function will use an xref:access.adoc[access control] modifier such as {Ownable-onlyOwner}.

```solidity
function _authorizeUpgrade(address) internal onlyOwner {}
```_

### pause

```solidity
function pause() external
```

Pauses cooperative state changes. Pull-payment withdrawals remain
callable so users can always claim funds they are already owed.

### unpause

```solidity
function unpause() external
```

Lifts a pause set by `pause()`.

### scheduleAction

```solidity
function scheduleAction(bytes32 actionType, bytes data) external returns (bytes32 actionId)
```

Schedules a privileged config change for execution after `TIMELOCK_DELAY`.

_Valid `actionType` values: `ACTION_SET_ARBITRATOR_POOL`,
`ACTION_SET_FEE_COLLECTOR`, `ACTION_WHITELIST_TOKEN`, `ACTION_REMOVE_TOKEN`.
Reverts if a tx with the same `(actionType, data, block.timestamp, block.number)`
has already been scheduled (collision case for same-block multi-call)._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| actionType | bytes32 | One of the four `ACTION_*` constants. |
| data | bytes | ABI-encoded arguments for the action (see action constants for shape). |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| actionId | bytes32 | Identifier to pass to `executeAction` or `cancelScheduledAction`. |

### executeAction

```solidity
function executeAction(bytes32 actionId) external
```

Executes a previously-scheduled action whose timelock has elapsed.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| actionId | bytes32 | The ID returned by `scheduleAction`. |

### cancelScheduledAction

```solidity
function cancelScheduledAction(bytes32 actionId) external
```

Cancels a pending (not-yet-executed) scheduled action.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| actionId | bytes32 | The ID returned by `scheduleAction`. |

### _setArbitratorPool

```solidity
function _setArbitratorPool(address[] newPool) internal
```

### _setFeeCollector

```solidity
function _setFeeCollector(address newCollector) internal
```

### _setTokenWhitelist

```solidity
function _setTokenWhitelist(address token, bool status) internal
```

### createTemplate

```solidity
function createTemplate(string name, string terms, uint256 recommendedDuration, uint256 recommendedMilestones) external returns (uint256 templateId)
```

Creates a new agreement template. Templates carry default terms,
a recommended duration, and a recommended milestone count that integrators
can use to seed the create-agreement form. Templates are owner-managed.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| name | string | Human-readable template name. |
| terms | string | Default terms text used by `createAgreementFromTemplate`. |
| recommendedDuration | uint256 | Recommended agreement length in seconds. Must be ≤ MAX_DEADLINE. |
| recommendedMilestones | uint256 | Recommended number of milestones. Must be ≤ MAX_MILESTONES. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| templateId | uint256 | Identifier for the new template. |

### updateTemplate

```solidity
function updateTemplate(uint256 templateId, string name, string terms, uint256 recommendedDuration, uint256 recommendedMilestones, bool isActive) external
```

Updates an existing template in place. Existing agreements are
unaffected because they snapshot the terms text at creation.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| templateId | uint256 | Existing template ID. |
| name | string | New name. |
| terms | string | New terms text. |
| recommendedDuration | uint256 | New recommended duration in seconds. |
| recommendedMilestones | uint256 | New recommended milestone count. |
| isActive | bool | Whether the template can seed new agreements. |

### createAgreementFromTemplate

```solidity
function createAgreementFromTemplate(uint256 templateId, address provider, uint256[] milestoneDueDates, uint256[] milestoneAmounts, address paymentToken) external payable returns (uint256)
```

Creates an agreement using the terms text from an existing template.
Funds are escrowed up front: for ETH send `msg.value == sum(milestoneAmounts)`;
for an ERC20, approve the contract for the same total before calling.

_`msg.sender` becomes the client. `provider` must differ from `msg.sender`.
Milestone deadlines must be strictly chronological and the last must not exceed
`block.timestamp + MAX_DEADLINE`. Each milestone amount must be non-zero. The
total amount must fit in `uint128`._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| templateId | uint256 | Active template providing the terms text. |
| provider | address | Service provider address. Cannot equal `msg.sender` or be zero. |
| milestoneDueDates | uint256[] | Per-milestone deadline timestamps; strictly increasing. |
| milestoneAmounts | uint256[] | Per-milestone payment amounts; non-zero. Sum equals total. |
| paymentToken | address | `address(0)` for ETH, otherwise a whitelisted ERC20. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | agreementId Identifier for the new agreement (also `agreementCount - 1`). |

### createAgreement

```solidity
function createAgreement(address provider, string terms, uint256[] milestoneDueDates, uint256[] milestoneAmounts, address paymentToken) external payable returns (uint256)
```

Creates an agreement with custom terms text (no template required).
All other validation is identical to `createAgreementFromTemplate`.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| provider | address | Service provider address. |
| terms | string | Free-form terms text recorded immutably on the agreement. |
| milestoneDueDates | uint256[] | Per-milestone deadline timestamps; strictly increasing. |
| milestoneAmounts | uint256[] | Per-milestone payment amounts. |
| paymentToken | address | `address(0)` for ETH, otherwise a whitelisted ERC20. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | agreementId Identifier for the new agreement. |

### _createAgreement

```solidity
function _createAgreement(address provider, string terms, uint256[] milestoneDueDates, uint256[] milestoneAmounts, address paymentToken) internal returns (uint256)
```

### proposeTeam

```solidity
function proposeTeam(uint256 agreementId, address[] members, uint256[] shares) external
```

Provider proposes a team payment split. The proposal does not take
effect until the client calls `approveTeam`. Until then, milestone payouts
are credited to `provider` directly. The provider may re-propose (overwriting
the previous proposal) at any time before approval.

_Shares are basis points (1 = 0.01%) and must sum exactly to `BASIS_POINTS`
(10,000). At most `MAX_TEAM_MEMBERS` (10). Each share must be non-zero. The
last team member absorbs rounding dust on each distribution.
Reverts:
  - `Unauthorized` if caller is not the provider.
  - `AgreementClosed` if cancelled / completed / disputed.
  - `TeamAlreadySet` if the team has already been approved.
  - `NoTeamMembers`, `TooManyTeamMembers`, `ArrayLengthMismatch`, `InvalidShares`, `ZeroAddress`._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |
| members | address[] | Recipient addresses for the split (length 1..MAX_TEAM_MEMBERS). |
| shares | uint256[] | Basis-point shares aligned to `members`; sum to `BASIS_POINTS`. |

### approveTeam

```solidity
function approveTeam(uint256 agreementId) external
```

Client approves the provider's most recent team proposal. After this
call, all subsequent milestone payouts are split per the proposed shares
(instead of being credited to the provider). Approval is final — neither
`proposeTeam` nor a second `approveTeam` will succeed afterward.

_Reverts: `Unauthorized` (not client), `AgreementClosed` (cancelled /
completed / disputed), `TeamAlreadySet`, `NoTeamProposed`._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |

### submitMilestoneEvidence

```solidity
function submitMilestoneEvidence(uint256 agreementId, uint256 milestoneIndex, string evidenceHash) external
```

Provider records evidence that a milestone is complete. Typically the
evidence is an IPFS / Arweave / Sia content hash — the contract treats it as
opaque bytes. Re-submitting overwrites the previous evidence (provider may
fix a bad hash). Once `approveMilestone` is called the milestone is paid and
further evidence updates are blocked.

_Blocked once the agreement is disputed; the existing evidence is what
the arbitrator will resolve against._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |
| milestoneIndex | uint256 | Zero-based milestone index. |
| evidenceHash | string | Non-empty content identifier (e.g., IPFS CID). |

### extendMilestoneDeadline

```solidity
function extendMilestoneDeadline(uint256 agreementId, uint256 milestoneIndex, uint256 newDeadline) external
```

Client extends the deadline of an unpaid milestone. The new deadline
must be later than the current one and within `MAX_DEADLINE` of `block.timestamp`.
If the new deadline exceeds `agreement.deadline`, the agreement deadline is
lifted to match (so the provider's dispute window cannot open prematurely).

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |
| milestoneIndex | uint256 | Zero-based milestone index. Must not be paid. |
| newDeadline | uint256 | New milestone deadline timestamp. |

### approveMilestone

```solidity
function approveMilestone(uint256 agreementId, uint256 milestoneIndex) external
```

Client approves a milestone, atomically marking it complete and
crediting the payment. The platform fee is deducted and credited to the fee
collector; the remainder goes to the provider — or, if `teamApproved`, to the
proposed team per their basis-point shares. Recipients claim with `withdraw`.

_Approve and pay are merged into a single call so a malicious provider
cannot front-run the client by inserting `raiseDispute` between the two._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |
| milestoneIndex | uint256 | Zero-based milestone index; must have evidence and be unpaid. |

### batchApproveMilestones

```solidity
function batchApproveMilestones(uint256 agreementId, uint256[] milestoneIndices) external
```

Approves and pays multiple milestones in one call. Same semantics as
`approveMilestone`, applied to each index. Reverts and rolls back if any
listed milestone is paid, missing evidence, or out of bounds.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |
| milestoneIndices | uint256[] | Zero-based milestone indices to approve. |

### _markCompletedIfFinal

```solidity
function _markCompletedIfFinal(struct ServiceAgreement.Agreement agreement) internal
```

### cancelAgreement

```solidity
function cancelAgreement(uint256 agreementId, string reason) external
```

Client cancels an agreement and gets their full remaining balance
credited back. Only valid within `CANCELLATION_WINDOW` (24h) of creation,
before any milestone is paid, and outside an active dispute.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |
| reason | string | Free-form reason recorded in the event. |

### raiseDispute

```solidity
function raiseDispute(uint256 agreementId, string reason) external
```

Raises a dispute that freezes the agreement until an arbitrator
resolves it via `resolveDispute`.

_Asymmetric rules:
  - The client may raise at any time (their funds are at risk).
  - The provider may only raise after `agreement.deadline` has elapsed
    (prevents front-running a client's `approveMilestone` to force arbitration).
Once disputed, all cooperative state changes (`approveMilestone`, evidence,
extensions, team proposals/approvals, cancellation) are blocked until
`resolveDispute`._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |
| reason | string | Free-form reason recorded in the event. |

### resolveDispute

```solidity
function resolveDispute(uint256 agreementId, uint256 amountToProvider) external
```

Arbitrator resolves a dispute by splitting the remaining escrowed
balance. `amountToProvider` (post platform fee) is credited to the provider
or team; the rest is refunded to the client. Either side of the split may
be zero. Resolution closes the agreement (`completed = true`).

_Only an address in the arbitrator pool may call._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |
| amountToProvider | uint256 | Portion of `remainingAmount` awarded to the provider                         side. Must be ≤ `remainingAmount`. |

### submitRating

```solidity
function submitRating(uint256 agreementId, address ratedAddress, uint256 score) external
```

Submits a 1–5 rating for the counterparty. Only valid after the
agreement is `completed` (final milestone approved or dispute resolved).
Each participant may rate exactly once per agreement; ratings are recorded
in `ratings[ratedAddress]` along with a transaction-value-weighted score
retrievable via `getUserRating`.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |
| ratedAddress | address | The counterparty being rated; must be the other party. |
| score | uint256 | Rating score in `[MIN_RATING, MAX_RATING]` (1..5 inclusive). |

### withdraw

```solidity
function withdraw(address token) external returns (uint256 amount)
```

Claims any pending balance owed to `msg.sender` in `token`. ETH or
any ERC20 (using `address(0)` for ETH). The balance is zeroed before transfer.
Reverts with `NothingToWithdraw` if no balance is owed.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| token | address | `address(0)` for ETH, otherwise the ERC20 token address. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| amount | uint256 | The amount transferred. |

### withdrawSurplus

```solidity
function withdrawSurplus(address token, address recipient) external
```

Owner withdraws only the surplus of `token` above
`totalObligations[token]`. Escrow and pending withdrawals are never touched.
Intended for accidental transfers, ETH sent via SELFDESTRUCT, or rebase dust.
Reverts with `NothingToWithdraw` if there is no surplus.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| token | address | `address(0)` for ETH, otherwise the ERC20 token address. |
| recipient | address | Non-zero recipient of the surplus. |

### _credit

```solidity
function _credit(address token, address recipient, uint256 amount) internal
```

### _distributeToProvider

```solidity
function _distributeToProvider(struct ServiceAgreement.Agreement agreement, address token, uint256 amount) internal
```

### _pullToken

```solidity
function _pullToken(address token, address from, uint256 amount) internal
```

### getAgreementDetails

```solidity
function getAgreementDetails(uint256 agreementId) external view returns (address client, address provider, uint256 totalAmount, uint256 remainingAmount, uint256 deadline, uint256 createdAt, bool completed, bool disputed, bool cancelled, address paymentToken, string terms)
```

Returns the top-level fields of an agreement.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| client | address | The client address. |
| provider | address | The provider address. |
| totalAmount | uint256 | Total escrow at creation. |
| remainingAmount | uint256 | Escrow not yet released or refunded. |
| deadline | uint256 | Last milestone deadline (kept in sync via `extendMilestoneDeadline`). |
| createdAt | uint256 | Creation timestamp. |
| completed | bool | True once all milestones are paid or a dispute was resolved. |
| disputed | bool | True between `raiseDispute` and `resolveDispute`. |
| cancelled | bool | True after `cancelAgreement`. |
| paymentToken | address | `address(0)` for ETH, otherwise an ERC20. |
| terms | string | The terms text recorded at creation. |

### getMilestoneCount

```solidity
function getMilestoneCount(uint256 agreementId) external view returns (uint256)
```

Number of milestones on an agreement.

### getMilestone

```solidity
function getMilestone(uint256 agreementId, uint256 milestoneIndex) external view returns (uint256 deadline, uint256 amount, bool completed, bool paid, string evidenceHash)
```

Returns a single milestone's fields.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| agreementId | uint256 | Agreement identifier. |
| milestoneIndex | uint256 | Zero-based milestone index. |

### getMilestones

```solidity
function getMilestones(uint256 agreementId) external view returns (struct ServiceAgreement.Milestone[])
```

Returns all milestones for an agreement as an array of structs.

_Capped by `MAX_MILESTONES` (20), so the size is bounded._

### getTeam

```solidity
function getTeam(uint256 agreementId) external view returns (address[] members, uint256[] shares)
```

Returns the agreement's proposed team split. Indices align between
`members` and `shares`. If empty, no team has been proposed.

_The split is only active for distributions if `teamApproved` is true,
which can be checked separately via `getAgreementDetails` is not — use
off-chain reads of the public getters or extend with a dedicated view._

### getUserAgreements

```solidity
function getUserAgreements(address user) external view returns (uint256[])
```

Returns all agreement IDs in which `user` is the client or provider.

_The list grows unboundedly; large users should expect non-trivial gas
for this view and may prefer off-chain indexing._

### getUserRating

```solidity
function getUserRating(address user) external view returns (uint256 total, uint256 count, uint256 average, uint256 weightedAverage)
```

Returns rating aggregates for a user.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| total | uint256 | Sum of all received scores. |
| count | uint256 | Number of received ratings. |
| average | uint256 | Unweighted mean (`total / count`, or 0 if count is 0). |
| weightedAverage | uint256 | Mean weighted by each agreement's `totalAmount`. |

### arbitratorPool

```solidity
function arbitratorPool() external view returns (address[])
```

Returns the current arbitrator pool. `isArbitrator(addr)` gives O(1) membership.

### arbitratorCount

```solidity
function arbitratorCount() external view returns (uint256)
```

Number of addresses in the current arbitrator pool.

### hasRated

```solidity
function hasRated(uint256 agreementId, address user) external view returns (bool)
```

Whether `user` has already submitted a rating for `agreementId`.

### receive

```solidity
receive() external payable
```

