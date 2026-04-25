// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @title ServiceAgreement
/// @notice Milestone-based escrow for service agreements between a client and a provider.
/// The client funds an agreement up front; the provider submits evidence per milestone;
/// the client approves to release payment. A platform fee (default 1%) is taken at
/// release. Disputes are resolved by an arbitrator from a configured pool.
/// @dev Six enforced design properties:
///
/// 1. **Pull payments.** All payouts credit `pendingWithdrawals[token][recipient]`.
///    Recipients claim with `withdraw(token)`. A refusing receiver only affects itself.
///
/// 2. **Real timelock on config + upgrades.** Every privileged config change and every
///    implementation upgrade goes through `scheduleAction → executeAction` (or
///    `requestUpgrade → upgradeToAndCall`) with a 2-day delay. No immediate bypass.
///
/// 3. **Solvency.** For every token, `balance(token) >= totalObligations[token]` at
///    all times. `withdrawSurplus` can only ever take the strict surplus.
///
/// 4. **Standard ERC20 only.** `_pullToken` reverts if `received != amount`,
///    rejecting fee-on-transfer and rebasing tokens.
///
/// 5. **Atomic milestone approve + pay.** `approveMilestone` marks the milestone
///    complete, decrements escrow, and credits the recipients in one transaction.
///    There is no separate "complete" step — eliminating the front-run window where
///    a malicious provider could `raiseDispute` between completion and payment.
///
/// 6. **Two-sided team payment authorization.** `proposeTeam` (provider) +
///    `approveTeam` (client). Until the client approves, payouts go to the provider.
contract ServiceAgreement is
    Initializable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ============ Errors ============

    error ZeroAddress();
    error InvalidProvider();
    error InvalidArrayLength();
    error ArrayLengthMismatch();
    error InvalidDeadline();
    error InvalidRating();
    error InvalidShares();
    error Unauthorized();
    error AgreementNotFound();
    error AgreementClosed();
    error AgreementNotDisputed();
    error AgreementNotComplete();
    error DisputeAlreadyRaised();
    error MilestoneIndexOutOfBounds();
    error MilestoneAlreadyPaid();
    error EvidenceMissing();
    error EvidenceEmpty();
    error MilestonesNotChronological();
    error TooManyMilestones();
    error TooManyTeamMembers();
    error NoTeamMembers();
    error TeamAlreadySet();
    error AlreadyRated();
    error CannotRateSelf();
    error TokenNotWhitelisted();
    error WrongPaymentAmount();
    error EthNotAcceptedForToken();
    error FeeOnTransferNotSupported();
    error TemplateNotFound();
    error TemplateNotActive();
    error DurationTooLong();
    error CancellationWindowExpired();
    error TimelockNotElapsed();
    error ActionAlreadyExecuted();
    error ActionNotFound();
    error NothingToWithdraw();
    error TransferFailed();
    error InsufficientFunds();
    error InvalidActionType();
    error NoTeamProposed();
    error TeamNotApproved();
    error NoDisputeGrounds();
    error UpgradeNotRequested();
    error ActionAlreadyScheduled();
    error TooManyArbitrators();

    // ============ Constants ============

    uint256 public constant MAX_MILESTONES = 20;
    uint256 public constant MAX_DEADLINE = 365 days;
    uint256 public constant PLATFORM_FEE_BPS = 100; // 1%
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MIN_RATING = 1;
    uint256 public constant MAX_RATING = 5;
    uint256 public constant CANCELLATION_WINDOW = 24 hours;
    uint256 public constant TIMELOCK_DELAY = 2 days;
    uint256 public constant MAX_TEAM_MEMBERS = 10;
    uint256 public constant MAX_ARBITRATORS = 10;

    // Action type identifiers for the timelock queue.
    bytes32 public constant ACTION_SET_ARBITRATOR_POOL = keccak256("SET_ARBITRATOR_POOL");
    bytes32 public constant ACTION_SET_FEE_COLLECTOR = keccak256("SET_FEE_COLLECTOR");
    bytes32 public constant ACTION_WHITELIST_TOKEN = keccak256("WHITELIST_TOKEN");
    bytes32 public constant ACTION_REMOVE_TOKEN = keccak256("REMOVE_TOKEN");

    // Sentinel for native ETH in token-keyed mappings.
    address public constant ETH = address(0);

    // ============ Types ============

    struct Milestone {
        uint64 deadline;
        uint128 amount;
        bool completed;
        bool paid;
        string evidenceHash;
    }

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
        bool teamApproved; // client has approved the provider's proposed team split
        address paymentToken; // ETH for native
        string terms;
        Milestone[] milestones;
        address[] teamMembers; // proposed by provider
        uint256[] teamShares; // basis points, must sum to BASIS_POINTS
        mapping(address => bool) hasRated;
    }

    struct Template {
        string name;
        string terms;
        uint256 recommendedDuration;
        uint256 recommendedMilestones;
        bool active;
    }

    struct Rating {
        uint256 total;
        uint256 count;
        uint256 weightedScore;
        uint256 totalTransactionValue;
    }

    struct PendingAction {
        bytes32 actionType;
        bytes data;
        uint256 executableAt;
        bool executed;
    }

    // ============ Storage ============

    // Agreements
    uint256 public agreementCount;
    mapping(uint256 => Agreement) private _agreements;
    mapping(address => uint256[]) private _userAgreements;

    // Templates
    uint256 public templateCount;
    mapping(uint256 => Template) public templates;

    // Ratings
    mapping(address => Rating) public ratings;

    // Tokens
    mapping(address => bool) public whitelistedTokens;

    // Admin
    address public feeCollector;
    address[] private _arbitratorList;
    mapping(address => bool) public isArbitrator;

    // Timelock queue
    mapping(bytes32 => PendingAction) public pendingActions;

    // Pull payments: token => recipient => claimable balance
    mapping(address => mapping(address => uint256)) public pendingWithdrawals;

    // Solvency invariant: contract balance(token) >= totalObligations[token].
    // Increases on agreement creation; decreases only when funds leave the contract.
    mapping(address => uint256) public totalObligations;

    // Upgrade timelock: implementation address => earliest authorized upgrade time.
    mapping(address => uint256) public upgradeRequestedAt;

    /// @dev Reserved for future upgrades. Decrement when adding new state variables.
    uint256[39] private __gap;

    // ============ Events ============

    event AgreementCreated(
        uint256 indexed agreementId,
        address indexed client,
        address indexed provider,
        uint256 totalAmount,
        uint256 milestoneCount,
        address paymentToken,
        string terms
    );
    event MilestoneEvidenceSubmitted(uint256 indexed agreementId, uint256 indexed milestoneIndex, string evidenceHash);
    event MilestoneApproved(uint256 indexed agreementId, uint256 indexed milestoneIndex, uint256 amount, uint256 fee);
    event BatchMilestonesApproved(uint256 indexed agreementId, uint256[] milestoneIndices, uint256 totalAmount, uint256 totalFee);
    event MilestoneDeadlineExtended(uint256 indexed agreementId, uint256 indexed milestoneIndex, uint256 newDeadline);
    event AgreementCancelled(uint256 indexed agreementId, address indexed initiator, string reason);
    event DisputeRaised(uint256 indexed agreementId, address indexed initiator, string reason);
    event DisputeResolved(uint256 indexed agreementId, uint256 amountToProvider, uint256 amountToClient);
    event RatingSubmitted(uint256 indexed agreementId, address indexed rater, address indexed rated, uint256 score);
    event TeamProposed(uint256 indexed agreementId, address[] members, uint256[] shares);
    event TeamApproved(uint256 indexed agreementId);
    event TemplateCreated(uint256 indexed templateId, string name);
    event TemplateUpdated(uint256 indexed templateId, string name, bool active);

    event TokenWhitelisted(address indexed token, bool status);
    event ArbitratorPoolUpdated(address[] arbitrators);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);

    event ActionScheduled(bytes32 indexed actionId, bytes32 actionType, bytes data, uint256 executableAt);
    event ActionExecuted(bytes32 indexed actionId);
    event ActionCancelled(bytes32 indexed actionId);

    event Withdrawn(address indexed token, address indexed recipient, uint256 amount);
    event SurplusWithdrawn(address indexed token, address indexed recipient, uint256 amount);

    event UpgradeRequested(address indexed newImplementation, uint256 executableAt);
    event UpgradeRequestCancelled(address indexed newImplementation);
    event ContractUpgraded(address indexed newImplementation);

    // ============ Modifiers ============

    modifier onlyClient(uint256 agreementId) {
        if (msg.sender != _agreements[agreementId].client) revert Unauthorized();
        _;
    }

    modifier onlyProvider(uint256 agreementId) {
        if (msg.sender != _agreements[agreementId].provider) revert Unauthorized();
        _;
    }

    modifier onlyParticipant(uint256 agreementId) {
        Agreement storage a = _agreements[agreementId];
        if (msg.sender != a.client && msg.sender != a.provider) revert Unauthorized();
        _;
    }

    modifier onlyArbitrator() {
        if (!isArbitrator[msg.sender]) revert Unauthorized();
        _;
    }

    modifier validAgreement(uint256 agreementId) {
        if (agreementId >= agreementCount) revert AgreementNotFound();
        _;
    }

    modifier active(uint256 agreementId) {
        Agreement storage a = _agreements[agreementId];
        if (a.cancelled || a.completed) revert AgreementClosed();
        _;
    }

    /// @dev Used to freeze cooperative state changes (team proposals, evidence,
    /// deadline edits) once a dispute is raised. Resolution is the only path
    /// out from a disputed state.
    modifier notDisputed(uint256 agreementId) {
        if (_agreements[agreementId].disputed) revert AgreementClosed();
        _;
    }

    // ============ Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy. Called once at deployment via the UUPS proxy.
    /// The caller becomes `owner`. Seeds the arbitrator pool with a single arbitrator;
    /// rotate later via the timelocked `scheduleAction(ACTION_SET_ARBITRATOR_POOL)`.
    /// @param arbitrator_ Initial arbitrator. Must be non-zero.
    /// @param feeCollector_ Address that receives the platform fee on each payout. Must be non-zero.
    function initialize(address arbitrator_, address feeCollector_) external initializer {
        if (arbitrator_ == address(0) || feeCollector_ == address(0)) revert ZeroAddress();

        __ReentrancyGuard_init();
        __Pausable_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        feeCollector = feeCollector_;
        _arbitratorList.push(arbitrator_);
        isArbitrator[arbitrator_] = true;

        emit ArbitratorPoolUpdated(_arbitratorList);
        emit FeeCollectorUpdated(address(0), feeCollector_);
    }

    /// @notice Schedules an upgrade to `newImplementation`. The upgrade itself (via
    /// `upgradeToAndCall`) only succeeds after `TIMELOCK_DELAY` has elapsed. Calling
    /// again for the same implementation overwrites the executable time, effectively
    /// resetting (or extending) the timelock for that target.
    /// @dev `_authorizeUpgrade` consumes the request on success.
    /// @param newImplementation Address of the new implementation contract. Must be non-zero.
    function requestUpgrade(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
        uint256 executableAt = block.timestamp + TIMELOCK_DELAY;
        upgradeRequestedAt[newImplementation] = executableAt;
        emit UpgradeRequested(newImplementation, executableAt);
    }

    /// @notice Cancels a previously-scheduled upgrade request.
    /// @param newImplementation Implementation address whose request should be cancelled.
    function cancelUpgradeRequest(address newImplementation) external onlyOwner {
        if (upgradeRequestedAt[newImplementation] == 0) revert ActionNotFound();
        delete upgradeRequestedAt[newImplementation];
        emit UpgradeRequestCancelled(newImplementation);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        uint256 executableAt = upgradeRequestedAt[newImplementation];
        if (executableAt == 0) revert UpgradeNotRequested();
        if (block.timestamp < executableAt) revert TimelockNotElapsed();
        delete upgradeRequestedAt[newImplementation];
        emit ContractUpgraded(newImplementation);
    }

    // ============ Pause ============

    /// @notice Pauses cooperative state changes. Pull-payment withdrawals remain
    /// callable so users can always claim funds they are already owed.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Lifts a pause set by `pause()`.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Timelock: schedule / execute / cancel ============

    /// @notice Schedules a privileged config change for execution after `TIMELOCK_DELAY`.
    /// @dev Valid `actionType` values: `ACTION_SET_ARBITRATOR_POOL`,
    /// `ACTION_SET_FEE_COLLECTOR`, `ACTION_WHITELIST_TOKEN`, `ACTION_REMOVE_TOKEN`.
    /// Reverts if a tx with the same `(actionType, data, block.timestamp, block.number)`
    /// has already been scheduled (collision case for same-block multi-call).
    /// @param actionType One of the four `ACTION_*` constants.
    /// @param data ABI-encoded arguments for the action (see action constants for shape).
    /// @return actionId Identifier to pass to `executeAction` or `cancelScheduledAction`.
    function scheduleAction(bytes32 actionType, bytes calldata data) external onlyOwner returns (bytes32 actionId) {
        if (
            actionType != ACTION_SET_ARBITRATOR_POOL &&
            actionType != ACTION_SET_FEE_COLLECTOR &&
            actionType != ACTION_WHITELIST_TOKEN &&
            actionType != ACTION_REMOVE_TOKEN
        ) {
            revert InvalidActionType();
        }

        actionId = keccak256(abi.encodePacked(actionType, data, block.timestamp, block.number));
        // Collisions only occur with same data in the same tx; revert to surface.
        if (pendingActions[actionId].executableAt != 0) revert ActionAlreadyScheduled();

        uint256 executableAt = block.timestamp + TIMELOCK_DELAY;
        pendingActions[actionId] = PendingAction({
            actionType: actionType,
            data: data,
            executableAt: executableAt,
            executed: false
        });

        emit ActionScheduled(actionId, actionType, data, executableAt);
    }

    /// @notice Executes a previously-scheduled action whose timelock has elapsed.
    /// @param actionId The ID returned by `scheduleAction`.
    function executeAction(bytes32 actionId) external onlyOwner {
        PendingAction storage action = pendingActions[actionId];
        if (action.executableAt == 0) revert ActionNotFound();
        if (action.executed) revert ActionAlreadyExecuted();
        if (block.timestamp < action.executableAt) revert TimelockNotElapsed();

        action.executed = true;

        bytes32 t = action.actionType;
        if (t == ACTION_SET_ARBITRATOR_POOL) {
            address[] memory pool = abi.decode(action.data, (address[]));
            _setArbitratorPool(pool);
        } else if (t == ACTION_SET_FEE_COLLECTOR) {
            address newCollector = abi.decode(action.data, (address));
            _setFeeCollector(newCollector);
        } else if (t == ACTION_WHITELIST_TOKEN) {
            address token = abi.decode(action.data, (address));
            _setTokenWhitelist(token, true);
        } else if (t == ACTION_REMOVE_TOKEN) {
            address token = abi.decode(action.data, (address));
            _setTokenWhitelist(token, false);
        } else {
            revert InvalidActionType();
        }

        emit ActionExecuted(actionId);
    }

    /// @notice Cancels a pending (not-yet-executed) scheduled action.
    /// @param actionId The ID returned by `scheduleAction`.
    function cancelScheduledAction(bytes32 actionId) external onlyOwner {
        PendingAction storage action = pendingActions[actionId];
        if (action.executableAt == 0) revert ActionNotFound();
        if (action.executed) revert ActionAlreadyExecuted();
        delete pendingActions[actionId];
        emit ActionCancelled(actionId);
    }

    // ============ Privileged config (internal applicators) ============

    function _setArbitratorPool(address[] memory newPool) internal {
        if (newPool.length == 0) revert InvalidArrayLength();
        if (newPool.length > MAX_ARBITRATORS) revert TooManyArbitrators();

        // Clear old pool.
        uint256 oldLen = _arbitratorList.length;
        for (uint256 i = 0; i < oldLen; i++) {
            isArbitrator[_arbitratorList[i]] = false;
        }
        delete _arbitratorList;

        // Set new pool with dedupe.
        for (uint256 i = 0; i < newPool.length; i++) {
            address arb = newPool[i];
            if (arb == address(0)) revert ZeroAddress();
            if (!isArbitrator[arb]) {
                isArbitrator[arb] = true;
                _arbitratorList.push(arb);
            }
        }

        emit ArbitratorPoolUpdated(_arbitratorList);
    }

    function _setFeeCollector(address newCollector) internal {
        if (newCollector == address(0)) revert ZeroAddress();
        address old = feeCollector;
        feeCollector = newCollector;
        emit FeeCollectorUpdated(old, newCollector);
    }

    function _setTokenWhitelist(address token, bool status) internal {
        if (token == address(0)) revert ZeroAddress();
        whitelistedTokens[token] = status;
        emit TokenWhitelisted(token, status);
    }

    // ============ Templates ============

    /// @notice Creates a new agreement template. Templates carry default terms,
    /// a recommended duration, and a recommended milestone count that integrators
    /// can use to seed the create-agreement form. Templates are owner-managed.
    /// @param name Human-readable template name.
    /// @param terms Default terms text used by `createAgreementFromTemplate`.
    /// @param recommendedDuration Recommended agreement length in seconds. Must be ≤ MAX_DEADLINE.
    /// @param recommendedMilestones Recommended number of milestones. Must be ≤ MAX_MILESTONES.
    /// @return templateId Identifier for the new template.
    function createTemplate(
        string calldata name,
        string calldata terms,
        uint256 recommendedDuration,
        uint256 recommendedMilestones
    ) external onlyOwner returns (uint256 templateId) {
        if (recommendedMilestones > MAX_MILESTONES) revert TooManyMilestones();
        if (recommendedDuration > MAX_DEADLINE) revert DurationTooLong();

        templateId = templateCount++;
        templates[templateId] = Template({
            name: name,
            terms: terms,
            recommendedDuration: recommendedDuration,
            recommendedMilestones: recommendedMilestones,
            active: true
        });
        emit TemplateCreated(templateId, name);
    }

    /// @notice Updates an existing template in place. Existing agreements are
    /// unaffected because they snapshot the terms text at creation.
    /// @param templateId Existing template ID.
    /// @param name New name.
    /// @param terms New terms text.
    /// @param recommendedDuration New recommended duration in seconds.
    /// @param recommendedMilestones New recommended milestone count.
    /// @param isActive Whether the template can seed new agreements.
    function updateTemplate(
        uint256 templateId,
        string calldata name,
        string calldata terms,
        uint256 recommendedDuration,
        uint256 recommendedMilestones,
        bool isActive
    ) external onlyOwner {
        if (templateId >= templateCount) revert TemplateNotFound();
        if (recommendedMilestones > MAX_MILESTONES) revert TooManyMilestones();
        if (recommendedDuration > MAX_DEADLINE) revert DurationTooLong();

        Template storage t = templates[templateId];
        t.name = name;
        t.terms = terms;
        t.recommendedDuration = recommendedDuration;
        t.recommendedMilestones = recommendedMilestones;
        t.active = isActive;

        emit TemplateUpdated(templateId, name, isActive);
    }

    // ============ Agreement creation ============

    /// @notice Creates an agreement using the terms text from an existing template.
    /// Funds are escrowed up front: for ETH send `msg.value == sum(milestoneAmounts)`;
    /// for an ERC20, approve the contract for the same total before calling.
    /// @dev `msg.sender` becomes the client. `provider` must differ from `msg.sender`.
    /// Milestone deadlines must be strictly chronological and the last must not exceed
    /// `block.timestamp + MAX_DEADLINE`. Each milestone amount must be non-zero. The
    /// total amount must fit in `uint128`.
    /// @param templateId Active template providing the terms text.
    /// @param provider Service provider address. Cannot equal `msg.sender` or be zero.
    /// @param milestoneDueDates Per-milestone deadline timestamps; strictly increasing.
    /// @param milestoneAmounts Per-milestone payment amounts; non-zero. Sum equals total.
    /// @param paymentToken `address(0)` for ETH, otherwise a whitelisted ERC20.
    /// @return agreementId Identifier for the new agreement (also `agreementCount - 1`).
    function createAgreementFromTemplate(
        uint256 templateId,
        address provider,
        uint256[] calldata milestoneDueDates,
        uint256[] calldata milestoneAmounts,
        address paymentToken
    ) external payable whenNotPaused returns (uint256) {
        if (templateId >= templateCount) revert TemplateNotFound();
        Template storage tpl = templates[templateId];
        if (!tpl.active) revert TemplateNotActive();

        return _createAgreement(provider, tpl.terms, milestoneDueDates, milestoneAmounts, paymentToken);
    }

    /// @notice Creates an agreement with custom terms text (no template required).
    /// All other validation is identical to `createAgreementFromTemplate`.
    /// @param provider Service provider address.
    /// @param terms Free-form terms text recorded immutably on the agreement.
    /// @param milestoneDueDates Per-milestone deadline timestamps; strictly increasing.
    /// @param milestoneAmounts Per-milestone payment amounts.
    /// @param paymentToken `address(0)` for ETH, otherwise a whitelisted ERC20.
    /// @return agreementId Identifier for the new agreement.
    function createAgreement(
        address provider,
        string calldata terms,
        uint256[] calldata milestoneDueDates,
        uint256[] calldata milestoneAmounts,
        address paymentToken
    ) external payable whenNotPaused returns (uint256) {
        return _createAgreement(provider, terms, milestoneDueDates, milestoneAmounts, paymentToken);
    }

    function _createAgreement(
        address provider,
        string memory terms,
        uint256[] calldata milestoneDueDates,
        uint256[] calldata milestoneAmounts,
        address paymentToken
    ) internal nonReentrant returns (uint256) {
        if (provider == address(0) || provider == msg.sender) revert InvalidProvider();
        uint256 n = milestoneDueDates.length;
        if (n == 0 || n > MAX_MILESTONES) revert InvalidArrayLength();
        if (n != milestoneAmounts.length) revert ArrayLengthMismatch();

        // Chronology + final-deadline cap.
        if (milestoneDueDates[0] <= block.timestamp) revert InvalidDeadline();
        for (uint256 i = 1; i < n; i++) {
            if (milestoneDueDates[i] <= milestoneDueDates[i - 1]) revert MilestonesNotChronological();
        }
        uint256 finalDeadline = milestoneDueDates[n - 1];
        if (finalDeadline > block.timestamp + MAX_DEADLINE) revert DurationTooLong();

        uint256 totalAmount;
        for (uint256 i = 0; i < n; i++) {
            if (milestoneAmounts[i] == 0) revert WrongPaymentAmount();
            totalAmount += milestoneAmounts[i];
        }
        if (totalAmount == 0 || totalAmount > type(uint128).max) revert WrongPaymentAmount();

        // Take payment.
        if (paymentToken == ETH) {
            if (msg.value != totalAmount) revert WrongPaymentAmount();
        } else {
            if (!whitelistedTokens[paymentToken]) revert TokenNotWhitelisted();
            if (msg.value != 0) revert EthNotAcceptedForToken();
            _pullToken(paymentToken, msg.sender, totalAmount);
        }
        totalObligations[paymentToken] += totalAmount;

        uint256 agreementId = agreementCount++;
        Agreement storage agreement = _agreements[agreementId];
        agreement.client = msg.sender;
        agreement.provider = provider;
        agreement.totalAmount = uint128(totalAmount);
        agreement.remainingAmount = uint128(totalAmount);
        agreement.deadline = uint64(finalDeadline);
        agreement.createdAt = uint64(block.timestamp);
        agreement.paymentToken = paymentToken;
        agreement.terms = terms;

        for (uint256 i = 0; i < n; i++) {
            agreement.milestones.push(
                Milestone({
                    deadline: uint64(milestoneDueDates[i]),
                    amount: uint128(milestoneAmounts[i]),
                    completed: false,
                    paid: false,
                    evidenceHash: ""
                })
            );
        }

        _userAgreements[msg.sender].push(agreementId);
        _userAgreements[provider].push(agreementId);

        emit AgreementCreated(agreementId, msg.sender, provider, totalAmount, n, paymentToken, terms);
        return agreementId;
    }

    // ============ Team payments ============

    /// @notice Provider proposes a team payment split. The proposal does not take
    /// effect until the client calls `approveTeam`. Until then, milestone payouts
    /// are credited to `provider` directly. The provider may re-propose (overwriting
    /// the previous proposal) at any time before approval.
    /// @dev Shares are basis points (1 = 0.01%) and must sum exactly to `BASIS_POINTS`
    /// (10,000). At most `MAX_TEAM_MEMBERS` (10). Each share must be non-zero. The
    /// last team member absorbs rounding dust on each distribution.
    /// Reverts:
    ///   - `Unauthorized` if caller is not the provider.
    ///   - `AgreementClosed` if cancelled / completed / disputed.
    ///   - `TeamAlreadySet` if the team has already been approved.
    ///   - `NoTeamMembers`, `TooManyTeamMembers`, `ArrayLengthMismatch`, `InvalidShares`, `ZeroAddress`.
    /// @param agreementId Agreement identifier.
    /// @param members Recipient addresses for the split (length 1..MAX_TEAM_MEMBERS).
    /// @param shares Basis-point shares aligned to `members`; sum to `BASIS_POINTS`.
    function proposeTeam(
        uint256 agreementId,
        address[] calldata members,
        uint256[] calldata shares
    ) external validAgreement(agreementId) onlyProvider(agreementId) active(agreementId) notDisputed(agreementId) whenNotPaused {
        Agreement storage agreement = _agreements[agreementId];
        if (agreement.teamApproved) revert TeamAlreadySet();

        uint256 n = members.length;
        if (n == 0) revert NoTeamMembers();
        if (n > MAX_TEAM_MEMBERS) revert TooManyTeamMembers();
        if (n != shares.length) revert ArrayLengthMismatch();

        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            if (members[i] == address(0)) revert ZeroAddress();
            if (shares[i] == 0) revert InvalidShares();
            sum += shares[i];
        }
        if (sum != BASIS_POINTS) revert InvalidShares();

        // Overwrite any previous proposal.
        delete agreement.teamMembers;
        delete agreement.teamShares;
        for (uint256 i = 0; i < n; i++) {
            agreement.teamMembers.push(members[i]);
            agreement.teamShares.push(shares[i]);
        }

        emit TeamProposed(agreementId, members, shares);
    }

    /// @notice Client approves the provider's most recent team proposal. After this
    /// call, all subsequent milestone payouts are split per the proposed shares
    /// (instead of being credited to the provider). Approval is final — neither
    /// `proposeTeam` nor a second `approveTeam` will succeed afterward.
    /// @dev Reverts: `Unauthorized` (not client), `AgreementClosed` (cancelled /
    /// completed / disputed), `TeamAlreadySet`, `NoTeamProposed`.
    /// @param agreementId Agreement identifier.
    function approveTeam(uint256 agreementId)
        external
        validAgreement(agreementId)
        onlyClient(agreementId)
        active(agreementId)
        notDisputed(agreementId)
        whenNotPaused
    {
        Agreement storage agreement = _agreements[agreementId];
        if (agreement.teamApproved) revert TeamAlreadySet();
        if (agreement.teamMembers.length == 0) revert NoTeamProposed();

        agreement.teamApproved = true;
        emit TeamApproved(agreementId);
    }

    // ============ Milestone lifecycle ============

    /// @notice Provider records evidence that a milestone is complete. Typically the
    /// evidence is an IPFS / Arweave / Sia content hash — the contract treats it as
    /// opaque bytes. Re-submitting overwrites the previous evidence (provider may
    /// fix a bad hash). Once `approveMilestone` is called the milestone is paid and
    /// further evidence updates are blocked.
    /// @dev Blocked once the agreement is disputed; the existing evidence is what
    /// the arbitrator will resolve against.
    /// @param agreementId Agreement identifier.
    /// @param milestoneIndex Zero-based milestone index.
    /// @param evidenceHash Non-empty content identifier (e.g., IPFS CID).
    function submitMilestoneEvidence(
        uint256 agreementId,
        uint256 milestoneIndex,
        string calldata evidenceHash
    ) external validAgreement(agreementId) onlyProvider(agreementId) active(agreementId) notDisputed(agreementId) whenNotPaused {
        if (bytes(evidenceHash).length == 0) revert EvidenceEmpty();

        Agreement storage agreement = _agreements[agreementId];
        if (milestoneIndex >= agreement.milestones.length) revert MilestoneIndexOutOfBounds();

        Milestone storage m = agreement.milestones[milestoneIndex];
        if (m.paid) revert MilestoneAlreadyPaid();
        m.evidenceHash = evidenceHash;

        emit MilestoneEvidenceSubmitted(agreementId, milestoneIndex, evidenceHash);
    }

    /// @notice Client extends the deadline of an unpaid milestone. The new deadline
    /// must be later than the current one and within `MAX_DEADLINE` of `block.timestamp`.
    /// If the new deadline exceeds `agreement.deadline`, the agreement deadline is
    /// lifted to match (so the provider's dispute window cannot open prematurely).
    /// @param agreementId Agreement identifier.
    /// @param milestoneIndex Zero-based milestone index. Must not be paid.
    /// @param newDeadline New milestone deadline timestamp.
    function extendMilestoneDeadline(uint256 agreementId, uint256 milestoneIndex, uint256 newDeadline)
        external
        validAgreement(agreementId)
        onlyClient(agreementId)
        active(agreementId)
        notDisputed(agreementId)
        whenNotPaused
    {
        Agreement storage agreement = _agreements[agreementId];
        if (milestoneIndex >= agreement.milestones.length) revert MilestoneIndexOutOfBounds();

        Milestone storage m = agreement.milestones[milestoneIndex];
        if (m.paid) revert MilestoneAlreadyPaid();
        if (newDeadline <= m.deadline) revert InvalidDeadline();
        if (newDeadline > block.timestamp + MAX_DEADLINE) revert DurationTooLong();

        m.deadline = uint64(newDeadline);
        // Keep agreement.deadline in sync so the provider's dispute window
        // (block.timestamp > agreement.deadline) reflects the latest extension.
        if (newDeadline > agreement.deadline) {
            agreement.deadline = uint64(newDeadline);
        }
        emit MilestoneDeadlineExtended(agreementId, milestoneIndex, newDeadline);
    }

    /// @notice Client approves a milestone, atomically marking it complete and
    /// crediting the payment. The platform fee is deducted and credited to the fee
    /// collector; the remainder goes to the provider — or, if `teamApproved`, to the
    /// proposed team per their basis-point shares. Recipients claim with `withdraw`.
    /// @dev Approve and pay are merged into a single call so a malicious provider
    /// cannot front-run the client by inserting `raiseDispute` between the two.
    /// @param agreementId Agreement identifier.
    /// @param milestoneIndex Zero-based milestone index; must have evidence and be unpaid.
    function approveMilestone(uint256 agreementId, uint256 milestoneIndex)
        external
        validAgreement(agreementId)
        onlyClient(agreementId)
        active(agreementId)
        notDisputed(agreementId)
        whenNotPaused
        nonReentrant
    {
        Agreement storage agreement = _agreements[agreementId];
        if (milestoneIndex >= agreement.milestones.length) revert MilestoneIndexOutOfBounds();

        Milestone storage m = agreement.milestones[milestoneIndex];
        if (m.paid) revert MilestoneAlreadyPaid();
        if (bytes(m.evidenceHash).length == 0) revert EvidenceMissing();

        m.completed = true;
        m.paid = true;

        uint256 amount = m.amount;
        uint256 fee = (amount * PLATFORM_FEE_BPS) / BASIS_POINTS;
        uint256 net = amount - fee;

        agreement.remainingAmount -= uint128(amount);
        _markCompletedIfFinal(agreement);

        address token = agreement.paymentToken;
        _credit(token, feeCollector, fee);
        _distributeToProvider(agreement, token, net);

        emit MilestoneApproved(agreementId, milestoneIndex, amount, fee);
    }

    /// @notice Approves and pays multiple milestones in one call. Same semantics as
    /// `approveMilestone`, applied to each index. Reverts and rolls back if any
    /// listed milestone is paid, missing evidence, or out of bounds.
    /// @param agreementId Agreement identifier.
    /// @param milestoneIndices Zero-based milestone indices to approve.
    function batchApproveMilestones(uint256 agreementId, uint256[] calldata milestoneIndices)
        external
        validAgreement(agreementId)
        onlyClient(agreementId)
        active(agreementId)
        notDisputed(agreementId)
        whenNotPaused
        nonReentrant
    {
        if (milestoneIndices.length == 0) revert InvalidArrayLength();

        Agreement storage agreement = _agreements[agreementId];

        uint256 totalAmount;
        uint256 totalFee;
        uint256 totalNet;
        uint256 mLen = agreement.milestones.length;

        for (uint256 i = 0; i < milestoneIndices.length; i++) {
            uint256 idx = milestoneIndices[i];
            if (idx >= mLen) revert MilestoneIndexOutOfBounds();

            Milestone storage m = agreement.milestones[idx];
            if (m.paid) revert MilestoneAlreadyPaid();
            if (bytes(m.evidenceHash).length == 0) revert EvidenceMissing();
            m.completed = true;
            m.paid = true;

            uint256 amount = m.amount;
            uint256 fee = (amount * PLATFORM_FEE_BPS) / BASIS_POINTS;

            totalAmount += amount;
            totalFee += fee;
            totalNet += (amount - fee);
        }

        agreement.remainingAmount -= uint128(totalAmount);
        _markCompletedIfFinal(agreement);

        address token = agreement.paymentToken;
        _credit(token, feeCollector, totalFee);
        _distributeToProvider(agreement, token, totalNet);

        emit BatchMilestonesApproved(agreementId, milestoneIndices, totalAmount, totalFee);
    }

    function _markCompletedIfFinal(Agreement storage agreement) internal {
        Milestone[] storage ms = agreement.milestones;
        uint256 n = ms.length;
        for (uint256 i = 0; i < n; i++) {
            if (!ms[i].paid) return;
        }
        agreement.completed = true;
    }

    // ============ Cancellation ============

    /// @notice Client cancels an agreement and gets their full remaining balance
    /// credited back. Only valid within `CANCELLATION_WINDOW` (24h) of creation,
    /// before any milestone is paid, and outside an active dispute.
    /// @param agreementId Agreement identifier.
    /// @param reason Free-form reason recorded in the event.
    function cancelAgreement(uint256 agreementId, string calldata reason)
        external
        validAgreement(agreementId)
        onlyClient(agreementId)
        active(agreementId)
        notDisputed(agreementId)
        whenNotPaused
        nonReentrant
    {
        Agreement storage agreement = _agreements[agreementId];
        if (block.timestamp > agreement.createdAt + CANCELLATION_WINDOW) revert CancellationWindowExpired();

        // Disallow cancellation after any milestone has been paid out.
        Milestone[] storage ms = agreement.milestones;
        uint256 n = ms.length;
        for (uint256 i = 0; i < n; i++) {
            if (ms[i].paid) revert AgreementClosed();
        }

        agreement.cancelled = true;
        uint256 refund = agreement.remainingAmount;
        agreement.remainingAmount = 0;

        _credit(agreement.paymentToken, agreement.client, refund);
        emit AgreementCancelled(agreementId, msg.sender, reason);
    }

    // ============ Dispute ============

    /// @notice Raises a dispute that freezes the agreement until an arbitrator
    /// resolves it via `resolveDispute`.
    /// @dev Asymmetric rules:
    ///   - The client may raise at any time (their funds are at risk).
    ///   - The provider may only raise after `agreement.deadline` has elapsed
    ///     (prevents front-running a client's `approveMilestone` to force arbitration).
    /// Once disputed, all cooperative state changes (`approveMilestone`, evidence,
    /// extensions, team proposals/approvals, cancellation) are blocked until
    /// `resolveDispute`.
    /// @param agreementId Agreement identifier.
    /// @param reason Free-form reason recorded in the event.
    function raiseDispute(uint256 agreementId, string calldata reason)
        external
        validAgreement(agreementId)
        onlyParticipant(agreementId)
        active(agreementId)
        whenNotPaused
    {
        Agreement storage agreement = _agreements[agreementId];
        if (agreement.disputed) revert DisputeAlreadyRaised();
        if (msg.sender == agreement.provider && block.timestamp <= agreement.deadline) {
            revert NoDisputeGrounds();
        }
        agreement.disputed = true;
        emit DisputeRaised(agreementId, msg.sender, reason);
    }

    /// @notice Arbitrator resolves a dispute by splitting the remaining escrowed
    /// balance. `amountToProvider` (post platform fee) is credited to the provider
    /// or team; the rest is refunded to the client. Either side of the split may
    /// be zero. Resolution closes the agreement (`completed = true`).
    /// @dev Only an address in the arbitrator pool may call.
    /// @param agreementId Agreement identifier.
    /// @param amountToProvider Portion of `remainingAmount` awarded to the provider
    ///                         side. Must be ≤ `remainingAmount`.
    function resolveDispute(uint256 agreementId, uint256 amountToProvider)
        external
        validAgreement(agreementId)
        onlyArbitrator
        whenNotPaused
        nonReentrant
    {
        Agreement storage agreement = _agreements[agreementId];
        if (!agreement.disputed) revert AgreementNotDisputed();

        uint256 remaining = agreement.remainingAmount;
        // Defensive: a disputed agreement should always have funds, but if state ever
        // drifts to remaining==0 we surface it instead of silently flipping completed.
        if (remaining == 0) revert AgreementClosed();
        if (amountToProvider > remaining) revert InsufficientFunds();

        uint256 toClient = remaining - amountToProvider;
        agreement.remainingAmount = 0;
        agreement.disputed = false;
        agreement.completed = true;

        address token = agreement.paymentToken;

        if (amountToProvider > 0) {
            uint256 fee = (amountToProvider * PLATFORM_FEE_BPS) / BASIS_POINTS;
            uint256 net = amountToProvider - fee;
            _credit(token, feeCollector, fee);
            _distributeToProvider(agreement, token, net);
        }
        if (toClient > 0) {
            _credit(token, agreement.client, toClient);
        }

        emit DisputeResolved(agreementId, amountToProvider, toClient);
    }

    // ============ Ratings ============

    /// @notice Submits a 1–5 rating for the counterparty. Only valid after the
    /// agreement is `completed` (final milestone approved or dispute resolved).
    /// Each participant may rate exactly once per agreement; ratings are recorded
    /// in `ratings[ratedAddress]` along with a transaction-value-weighted score
    /// retrievable via `getUserRating`.
    /// @param agreementId Agreement identifier.
    /// @param ratedAddress The counterparty being rated; must be the other party.
    /// @param score Rating score in `[MIN_RATING, MAX_RATING]` (1..5 inclusive).
    function submitRating(uint256 agreementId, address ratedAddress, uint256 score)
        external
        validAgreement(agreementId)
        onlyParticipant(agreementId)
        whenNotPaused
    {
        if (score < MIN_RATING || score > MAX_RATING) revert InvalidRating();
        if (ratedAddress == msg.sender) revert CannotRateSelf();

        Agreement storage agreement = _agreements[agreementId];
        if (!agreement.completed) revert AgreementNotComplete();
        if (ratedAddress != agreement.client && ratedAddress != agreement.provider) revert Unauthorized();
        if (agreement.hasRated[msg.sender]) revert AlreadyRated();

        agreement.hasRated[msg.sender] = true;

        Rating storage r = ratings[ratedAddress];
        r.total += score;
        r.count += 1;

        uint256 weight = agreement.totalAmount;
        r.weightedScore += score * weight;
        r.totalTransactionValue += weight;

        emit RatingSubmitted(agreementId, msg.sender, ratedAddress, score);
    }

    // ============ Pull payments ============

    /// @notice Claims any pending balance owed to `msg.sender` in `token`. ETH or
    /// any ERC20 (using `address(0)` for ETH). The balance is zeroed before transfer.
    /// Reverts with `NothingToWithdraw` if no balance is owed.
    /// @param token `address(0)` for ETH, otherwise the ERC20 token address.
    /// @return amount The amount transferred.
    function withdraw(address token) external nonReentrant returns (uint256 amount) {
        amount = pendingWithdrawals[token][msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[token][msg.sender] = 0;
        totalObligations[token] -= amount;

        if (token == ETH) {
            (bool ok, ) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        emit Withdrawn(token, msg.sender, amount);
    }

    // ============ Emergency / surplus withdraw ============

    /// @notice Owner withdraws only the surplus of `token` above
    /// `totalObligations[token]`. Escrow and pending withdrawals are never touched.
    /// Intended for accidental transfers, ETH sent via SELFDESTRUCT, or rebase dust.
    /// Reverts with `NothingToWithdraw` if there is no surplus.
    /// @param token `address(0)` for ETH, otherwise the ERC20 token address.
    /// @param recipient Non-zero recipient of the surplus.
    function withdrawSurplus(address token, address recipient) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 balance = token == ETH ? address(this).balance : IERC20(token).balanceOf(address(this));
        uint256 obligated = totalObligations[token];
        if (balance <= obligated) revert NothingToWithdraw();
        uint256 surplus = balance - obligated;

        if (token == ETH) {
            (bool ok, ) = recipient.call{value: surplus}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(recipient, surplus);
        }
        emit SurplusWithdrawn(token, recipient, surplus);
    }

    // ============ Internal helpers ============

    function _credit(address token, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        pendingWithdrawals[token][recipient] += amount;
    }

    function _distributeToProvider(Agreement storage agreement, address token, uint256 amount) internal {
        if (amount == 0) return;
        // Until the client approves the team split, payouts go to the provider.
        if (!agreement.teamApproved) {
            _credit(token, agreement.provider, amount);
            return;
        }
        address[] storage members = agreement.teamMembers;
        uint256 n = members.length;
        // teamApproved implies n > 0, but guard for completeness.
        if (n == 0) {
            _credit(token, agreement.provider, amount);
            return;
        }
        uint256[] storage shares = agreement.teamShares;
        uint256 distributed;
        for (uint256 i = 0; i < n - 1; i++) {
            uint256 share = (amount * shares[i]) / BASIS_POINTS;
            distributed += share;
            _credit(token, members[i], share);
        }
        // Last team member absorbs rounding dust.
        _credit(token, members[n - 1], amount - distributed);
    }

    function _pullToken(address token, address from, uint256 amount) internal {
        IERC20 t = IERC20(token);
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(from, address(this), amount);
        uint256 received = t.balanceOf(address(this)) - before;
        if (received != amount) revert FeeOnTransferNotSupported();
    }

    // ============ Views ============

    /// @notice Returns the top-level fields of an agreement.
    /// @param agreementId Agreement identifier.
    /// @return client The client address.
    /// @return provider The provider address.
    /// @return totalAmount Total escrow at creation.
    /// @return remainingAmount Escrow not yet released or refunded.
    /// @return deadline Last milestone deadline (kept in sync via `extendMilestoneDeadline`).
    /// @return createdAt Creation timestamp.
    /// @return completed True once all milestones are paid or a dispute was resolved.
    /// @return disputed True between `raiseDispute` and `resolveDispute`.
    /// @return cancelled True after `cancelAgreement`.
    /// @return paymentToken `address(0)` for ETH, otherwise an ERC20.
    /// @return terms The terms text recorded at creation.
    function getAgreementDetails(uint256 agreementId)
        external
        view
        validAgreement(agreementId)
        returns (
            address client,
            address provider,
            uint256 totalAmount,
            uint256 remainingAmount,
            uint256 deadline,
            uint256 createdAt,
            bool completed,
            bool disputed,
            bool cancelled,
            address paymentToken,
            string memory terms
        )
    {
        Agreement storage a = _agreements[agreementId];
        return (
            a.client,
            a.provider,
            a.totalAmount,
            a.remainingAmount,
            a.deadline,
            a.createdAt,
            a.completed,
            a.disputed,
            a.cancelled,
            a.paymentToken,
            a.terms
        );
    }

    /// @notice Number of milestones on an agreement.
    function getMilestoneCount(uint256 agreementId) external view validAgreement(agreementId) returns (uint256) {
        return _agreements[agreementId].milestones.length;
    }

    /// @notice Returns a single milestone's fields.
    /// @param agreementId Agreement identifier.
    /// @param milestoneIndex Zero-based milestone index.
    function getMilestone(uint256 agreementId, uint256 milestoneIndex)
        external
        view
        validAgreement(agreementId)
        returns (uint256 deadline, uint256 amount, bool completed, bool paid, string memory evidenceHash)
    {
        Agreement storage a = _agreements[agreementId];
        if (milestoneIndex >= a.milestones.length) revert MilestoneIndexOutOfBounds();
        Milestone storage m = a.milestones[milestoneIndex];
        return (m.deadline, m.amount, m.completed, m.paid, m.evidenceHash);
    }

    /// @notice Returns all milestones for an agreement as an array of structs.
    /// @dev Capped by `MAX_MILESTONES` (20), so the size is bounded.
    function getMilestones(uint256 agreementId)
        external
        view
        validAgreement(agreementId)
        returns (Milestone[] memory)
    {
        return _agreements[agreementId].milestones;
    }

    /// @notice Returns the agreement's proposed team split. Indices align between
    /// `members` and `shares`. If empty, no team has been proposed.
    /// @dev The split is only active for distributions if `teamApproved` is true,
    /// which can be checked separately via `getAgreementDetails` is not — use
    /// off-chain reads of the public getters or extend with a dedicated view.
    function getTeam(uint256 agreementId)
        external
        view
        validAgreement(agreementId)
        returns (address[] memory members, uint256[] memory shares)
    {
        Agreement storage a = _agreements[agreementId];
        return (a.teamMembers, a.teamShares);
    }

    /// @notice Returns all agreement IDs in which `user` is the client or provider.
    /// @dev The list grows unboundedly; large users should expect non-trivial gas
    /// for this view and may prefer off-chain indexing.
    function getUserAgreements(address user) external view returns (uint256[] memory) {
        return _userAgreements[user];
    }

    /// @notice Returns rating aggregates for a user.
    /// @return total Sum of all received scores.
    /// @return count Number of received ratings.
    /// @return average Unweighted mean (`total / count`, or 0 if count is 0).
    /// @return weightedAverage Mean weighted by each agreement's `totalAmount`.
    function getUserRating(address user)
        external
        view
        returns (uint256 total, uint256 count, uint256 average, uint256 weightedAverage)
    {
        Rating storage r = ratings[user];
        total = r.total;
        count = r.count;
        average = count > 0 ? total / count : 0;
        weightedAverage = r.totalTransactionValue > 0 ? r.weightedScore / r.totalTransactionValue : 0;
    }

    /// @notice Returns the current arbitrator pool. `isArbitrator(addr)` gives O(1) membership.
    function arbitratorPool() external view returns (address[] memory) {
        return _arbitratorList;
    }

    /// @notice Number of addresses in the current arbitrator pool.
    function arbitratorCount() external view returns (uint256) {
        return _arbitratorList.length;
    }

    /// @notice Whether `user` has already submitted a rating for `agreementId`.
    function hasRated(uint256 agreementId, address user) external view validAgreement(agreementId) returns (bool) {
        return _agreements[agreementId].hasRated[user];
    }

    // ============ Receive (used only via withdraw / refunds) ============

    receive() external payable {
        // Accept ETH; surplus is withdrawable by the owner via withdrawSurplus.
    }
}
