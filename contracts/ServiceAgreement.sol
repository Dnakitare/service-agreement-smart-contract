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
/// @notice Milestone-based escrow for service agreements between a client and provider.
/// @dev Key design properties:
///      - Pull payments: recipients call withdraw() instead of receiving pushed transfers.
///        This prevents a single bad team member from blocking everyone else.
///      - Real timelock: every privileged config change schedules an action that can only
///        be executed after TIMELOCK_DELAY. There is no immediate-execute bypass.
///      - Solvency invariant: for every accepted token, the contract balance is always
///        >= totalObligations[token]. emergencyWithdraw can only take the surplus.
///      - Fee-on-transfer / rebasing tokens are rejected at deposit time to keep the
///        invariant exact. Whitelisted tokens are expected to be standard ERC20s.
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

    /// @notice Schedule an upgrade to a specific implementation. The upgrade itself
    /// (via UUPSUpgradeable.upgradeToAndCall) becomes executable after TIMELOCK_DELAY.
    /// Re-requesting for the same implementation overwrites the schedule.
    function requestUpgrade(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
        uint256 executableAt = block.timestamp + TIMELOCK_DELAY;
        upgradeRequestedAt[newImplementation] = executableAt;
        emit UpgradeRequested(newImplementation, executableAt);
    }

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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Timelock: schedule / execute / cancel ============

    /// @notice Schedule a privileged config change. Owner-only. Becomes executable
    /// after TIMELOCK_DELAY. Reverts if an identical action with the same nonce is
    /// already pending.
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

    /// @notice Create an agreement seeded from a template. Funds are escrowed up front.
    /// For ETH: send msg.value == sum(milestoneAmounts). For ERC20: approve first.
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

    /// @notice Create an agreement with custom terms (no template).
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

    /// @notice Provider proposes a team payment split. Provider may re-propose
    /// (overwriting the previous proposal) until the client approves it. Once
    /// approved by `approveTeam`, the split is locked.
    /// @dev Shares are basis points and must sum to BASIS_POINTS.
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

    /// @notice Client approves the provider's most recent team proposal. After
    /// approval, future milestone payouts are split among the proposed members.
    /// Approval is final; provider cannot re-propose afterward.
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

    /// @notice Client approves a milestone and atomically releases its payment.
    /// Marking a milestone complete and paying are a single tx so a malicious
    /// provider cannot front-run the client's release with a `raiseDispute` to
    /// force arbitration.
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

    /// @notice Client may cancel within CANCELLATION_WINDOW of creation, only if no
    /// milestone has been paid and no dispute is active. The full remaining balance
    /// is credited back to the client (claim via withdraw()).
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

    /// @notice Raise a dispute. Either party may dispute, but with asymmetric rules:
    ///   - The client may dispute at any time (their funds are at risk).
    ///   - The provider may only dispute after the agreement deadline has elapsed,
    ///     which prevents them from front-running the client's `approveMilestone`
    ///     to force arbitration on work the client was about to pay for.
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

    /// @notice Resolve a dispute by splitting the remaining escrowed funds.
    /// `amountToProvider` of the remaining balance goes to the provider (minus
    /// platform fee), the rest is refunded to the client. Either may be zero.
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

    /// @notice Submit a rating for the counterparty. Only valid after the agreement
    /// is fully completed (all milestones paid or dispute resolved). Each address may
    /// rate once per agreement.
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

    /// @notice Claim any pending balance owed to the caller in the given token.
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

    /// @notice Owner may withdraw only the surplus above totalObligations[token].
    /// User-escrowed funds and credited (pending-withdrawal) balances are protected.
    /// This is intended for accidental transfers, dust, or rebases.
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

    function getMilestoneCount(uint256 agreementId) external view validAgreement(agreementId) returns (uint256) {
        return _agreements[agreementId].milestones.length;
    }

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

    function getMilestones(uint256 agreementId)
        external
        view
        validAgreement(agreementId)
        returns (Milestone[] memory)
    {
        return _agreements[agreementId].milestones;
    }

    function getTeam(uint256 agreementId)
        external
        view
        validAgreement(agreementId)
        returns (address[] memory members, uint256[] memory shares)
    {
        Agreement storage a = _agreements[agreementId];
        return (a.teamMembers, a.teamShares);
    }

    function getUserAgreements(address user) external view returns (uint256[] memory) {
        return _userAgreements[user];
    }

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

    function arbitratorPool() external view returns (address[] memory) {
        return _arbitratorList;
    }

    function arbitratorCount() external view returns (uint256) {
        return _arbitratorList.length;
    }

    function hasRated(uint256 agreementId, address user) external view validAgreement(agreementId) returns (bool) {
        return _agreements[agreementId].hasRated[user];
    }

    // ============ Receive (used only via withdraw / refunds) ============

    receive() external payable {
        // Accept ETH; surplus is withdrawable by the owner via withdrawSurplus.
    }
}
