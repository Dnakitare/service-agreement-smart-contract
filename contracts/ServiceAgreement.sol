// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract ServiceAgreement is ReentrancyGuard, Pausable, Ownable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // Custom errors for gas optimization
    error InvalidAddress();
    error InvalidAmount();
    error InvalidMilestone();
    error InvalidDeadline();
    error InvalidPercentage();
    error InvalidArrayLength();
    error OnlyClientAllowed();
    error OnlyProviderAllowed();
    error OnlyParticipantAllowed();
    error OnlyArbitratorAllowed();
    error AgreementNotFound();
    error AlreadyRated();
    error AgreementCancelled();
    error AgreementDisputed();
    error AgreementCompleted();
    error MilestoneCompleted();
    error MilestoneNotCompleted();
    error MilestoneAlreadyPaid();
    error NoEvidenceSubmitted();
    error TeamAlreadySet();
    error EmptyArbitratorPool();
    error PaymentFailed();
    error TokenNotWhitelisted();
    error IncorrectPaymentAmount();
    error TooManyMilestones();
    error DurationTooLong();
    error TemplateNotActive();
    error TemplateNotFound();
    error SharesMustTotal100Percent();
    error AgreementNotDisputed();
    error MaxEscalationReached();
    error EscalationPeriodNotMet();
    error NoProposedChange();
    error ChangeAlreadyApproved();
    error InsufficientRemainingFunds();
    error CancellationPeriodExpired();
    error DisputeAlreadyRaised();
    error EmptyEvidenceHash();
    error InvalidRating();
    error CannotRateSelf();
    error NoTokensToWithdraw();
    error InvalidProvider();
    error PaymentRequired();
    error ArrayLengthMismatch();
    error EthNotAcceptedForTokenPayments();
    error NoMembersProvided();
    error InvalidMilestoneIndex();
    error AgreementNotCompleted();

    // Packed storage for gas optimization
    struct Milestone {
        uint64 deadline;
        uint128 amount;
        bool completed;
        bool paid;
        bool partiallyCompleted;  // New field for partial completion
        uint8 completionPercentage; // New field for partial completion percentage
        string evidenceHash;  // IPFS hash of completion evidence
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
        address paymentToken;
        string terms;
        Milestone[] milestones;
        mapping(address => bool) hasRated;
        address[] teamMembers; // New field for team providers
        uint256[] teamShares;  // New field for payment splitting
    }

    struct AgreementTemplate {
        string name;
        string terms;
        uint256 recommendedDuration;
        uint256 recommendedMilestones;
        bool active;
    }

    struct Rating {
        uint256 total;
        uint256 count;
        uint256 weightedScore;  // Weighted by transaction amounts
        uint256 totalTransactionValue;
    }

    // Constants
    uint256 public constant MAX_MILESTONES = 20;
    uint256 public constant MAX_DEADLINE = 365 days;
    uint256 public constant PLATFORM_FEE_PERCENTAGE = 100; // 1% (basis points)
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_RATING = 1;
    uint256 public constant MAX_RATING = 5;
    uint256 public constant CANCELLATION_TIMEFRAME = 24 hours;
    uint256 public constant DISPUTE_RESOLUTION_TIMEFRAME = 14 days; // New constant
    uint256 public constant TIMELOCK_DURATION = 2 days;
    uint256 public constant ESCALATION_PERIOD = 7 days;

    // State variables
    mapping(uint256 => Agreement) public agreements;
    mapping(address => Rating) public ratings;
    mapping(address => uint256[]) public userAgreements;
    mapping(uint256 => AgreementTemplate) public templates;
    mapping(address => bool) public whitelistedTokens;
    uint256 public agreementCount;
    uint256 public templateCount;
    address public arbitrator;
    address[] public arbitratorPool; // New field for multi-arbitrator support
    address public feeCollector;
    
    // For upgradeable contracts
    uint256[50] private __gap;

    struct PendingAction {
        bytes32 actionType;
        bytes data;
        uint256 timestamp;
        bool executed;
    }
    
    mapping(bytes32 => PendingAction) public pendingActions;
    
    // Action type constants
    bytes32 public constant ACTION_SET_ARBITRATOR = keccak256("SET_ARBITRATOR");
    bytes32 public constant ACTION_SET_FEE_COLLECTOR = keccak256("SET_FEE_COLLECTOR");
    bytes32 public constant ACTION_WHITELIST_TOKEN = keccak256("WHITELIST_TOKEN");
    bytes32 public constant ACTION_REMOVE_TOKEN = keccak256("REMOVE_TOKEN");

    // Events
    event TokenWhitelisted(address indexed token, bool status);
    event AgreementCreated(
        uint256 indexed id,
        address indexed client,
        address indexed provider,
        uint256 totalAmount,
        uint256 milestones,
        address paymentToken,
        string terms
    );
    event MilestoneCompleted(uint256 indexed id, uint256 milestone, uint256 timestamp);
    event MilestoneDeadlineExtended(
        uint256 indexed agreementId,
        uint256 milestoneIndex,
        uint256 newDeadline
    );
    event PaymentReleased(uint256 indexed id, uint256 milestone, uint256 amount, uint256 fee);
    event DisputeRaised(uint256 indexed id, address initiator, string reason);
    event DisputeResolved(uint256 indexed id, address winner);
    event MilestoneEvidenceSubmitted(uint256 indexed agreementId, uint256 milestoneIndex, string evidenceHash);
    event AgreementCancelled(uint256 indexed agreementId, address initiator, string reason);
    event AgreementModified(uint256 indexed agreementId, string changes);
    event RatingSubmitted(uint256 indexed agreementId, address indexed rater, address indexed rated, uint256 score);
    event TemplateCreated(uint256 indexed templateId, string name);
    event TemplateUpdated(uint256 indexed templateId, string name, bool active);
    event ArbitratorUpdated(address indexed oldArbitrator, address indexed newArbitrator);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event PartialMilestoneCompleted(uint256 indexed id, uint256 milestone, uint8 percentage, uint256 timestamp);
    event ArbitratorPoolUpdated(address[] arbitrators);
    event TeamMemberAdded(uint256 indexed agreementId, address member, uint256 share);
    event AgreementUpgraded(uint256 indexed agreementId, string details);
    event BatchPaymentReleased(uint256 indexed id, uint256[] milestones, uint256 totalAmount, uint256 totalFee);
    event ActionScheduled(bytes32 indexed actionId, bytes32 actionType, bytes data, uint256 executionTime);
    event ActionExecuted(bytes32 indexed actionId);
    event ActionCancelled(bytes32 indexed actionId);
    event DisputeEscalated(uint256 indexed agreementId, address indexed escalator, uint256 newLevel, string reason);
    event MilestoneChangeProposed(uint256 indexed agreementId, uint256 milestoneIndex, address proposer, uint256 newDeadline, uint256 newAmount);
    event MilestoneChangeApproved(uint256 indexed agreementId, uint256 milestoneIndex, address approver);
    event MilestoneChanged(uint256 indexed agreementId, uint256 milestoneIndex, uint256 newDeadline, uint256 newAmount);

    // New state variables
    mapping(uint256 => uint256) public disputeEscalationLevel;
    mapping(uint256 => mapping(address => string)) public disputeEvidence;

    struct MilestoneChange {
        uint64 newDeadline;
        uint128 newAmount;
        bool clientApproved;
        bool providerApproved;
    }

    mapping(uint256 => mapping(uint256 => MilestoneChange)) public proposedMilestoneChanges;

    // Modifiers
    modifier onlyClient(uint256 agreementId) {
        if (msg.sender != agreements[agreementId].client) revert OnlyClientAllowed();
        _;
    }

    modifier onlyProvider(uint256 agreementId) {
        if (msg.sender != agreements[agreementId].provider) revert OnlyProviderAllowed();
        _;
    }

    modifier onlyParticipant(uint256 agreementId) {
        if (msg.sender != agreements[agreementId].client && 
            msg.sender != agreements[agreementId].provider) {
            revert OnlyParticipantAllowed();
        }
        _;
    }

    modifier onlyArbitrator() {
        if (msg.sender != arbitrator) revert OnlyArbitratorAllowed();
        _;
    }

    modifier onlyArbitratorPool() {
        bool isArbitrator = false;
        for (uint i = 0; i < arbitratorPool.length; i++) {
            if (msg.sender == arbitratorPool[i]) {
                isArbitrator = true;
                break;
            }
        }
        if (!isArbitrator) revert OnlyArbitratorAllowed();
        _;
    }

    modifier validAgreement(uint256 agreementId) {
        if (agreementId >= agreementCount) revert AgreementNotFound();
        _;
    }

    modifier onlyUnrated(uint256 agreementId) {
        if (agreements[agreementId].hasRated[msg.sender]) revert AlreadyRated();
        _;
    }

    modifier notCancelled(uint256 agreementId) {
        if (agreements[agreementId].cancelled) revert AgreementCancelled();
        _;
    }

    // Initialize function for upgradeable contracts
    function initialize(address _arbitrator, address _feeCollector) public initializer {
        require(_arbitrator != address(0), "Invalid arbitrator address");
        require(_feeCollector != address(0), "Invalid fee collector address");
        arbitrator = _arbitrator;
        feeCollector = _feeCollector;
        
        // Initialize arbitrator pool with the main arbitrator
        arbitratorPool.push(_arbitrator);
        
        // Initialize Ownable
        __Ownable_init(msg.sender);
        __Ownable_init_unchained();
        
        // Initialize other inherited contracts
        __Pausable_init();
        __UUPSUpgradeable_init();
    }
    
    // Required for UUPS upgradeable pattern
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Add implementation-specific validation if needed
        emit AgreementUpgraded(0, "Contract implementation upgraded");
    }

    // Template Management Functions
    function createTemplate(
        string calldata name,
        string calldata terms,
        uint256 recommendedDuration,
        uint256 recommendedMilestones
    ) external onlyOwner returns (uint256) {
        if (recommendedMilestones > MAX_MILESTONES) revert TooManyMilestones();
        if (recommendedDuration > MAX_DEADLINE) revert DurationTooLong();

        uint256 templateId = templateCount++;
        templates[templateId] = AgreementTemplate({
            name: name,
            terms: terms,
            recommendedDuration: recommendedDuration,
            recommendedMilestones: recommendedMilestones,
            active: true
        });

        emit TemplateCreated(templateId, name);
        return templateId;
    }

    function updateTemplate(
        uint256 templateId,
        string calldata name,
        string calldata terms,
        uint256 recommendedDuration,
        uint256 recommendedMilestones,
        bool active
    ) external onlyOwner {
        if (templateId >= templateCount) revert TemplateNotFound();
        if (recommendedMilestones > MAX_MILESTONES) revert TooManyMilestones();
        if (recommendedDuration > MAX_DEADLINE) revert DurationTooLong();

        AgreementTemplate storage template = templates[templateId];
        template.name = name;
        template.terms = terms;
        template.recommendedDuration = recommendedDuration;
        template.recommendedMilestones = recommendedMilestones;
        template.active = active;

        emit TemplateUpdated(templateId, name, active);
    }

    // Agreement Creation and Management Functions
    /**
     * @notice Creates a new agreement from a template
     * @dev Uses a template to create an agreement with customized milestones
     * @param templateId The ID of the template to use
     * @param provider The address of the service provider
     * @param milestoneDueDates Array of milestone deadlines (timestamps)
     * @param milestoneAmounts Array of payment amounts for each milestone
     * @param paymentToken Address of the ERC20 token for payment (address(0) for ETH)
     * @return The ID of the newly created agreement
     */
    function createAgreementFromTemplate(
        uint256 templateId,
        address provider,
        uint256[] calldata milestoneDueDates,
        uint256[] calldata milestoneAmounts,
        address paymentToken
    ) external payable whenNotPaused returns (uint256) {
        AgreementTemplate storage template = templates[templateId];
        if (!template.active) revert TemplateNotActive();
        
        uint256 totalAmount = 0;
        for(uint256 i = 0; i < milestoneAmounts.length; i++) {
            totalAmount += milestoneAmounts[i];
        }

        return _createAgreement(
            provider,
            template.terms,
            milestoneDueDates[milestoneDueDates.length - 1],
            milestoneDueDates,
            milestoneAmounts,
            paymentToken,
            totalAmount
        );
    }

    /**
     * @notice Creates an agreement with custom parameters
     * @dev Internal function used by createAgreementFromTemplate
     * @param provider The address of the service provider
     * @param terms The terms of the agreement
     * @param deadline The overall deadline for the agreement
     * @param milestoneDueDates Array of milestone deadlines
     * @param milestoneAmounts Array of payment amounts for each milestone
     * @param paymentToken Address of the ERC20 token for payment (address(0) for ETH)
     * @param totalAmount Total payment amount for the agreement
     * @return The ID of the newly created agreement
     */
    function _createAgreement(
        address provider,
        string memory terms,
        uint256 deadline,
        uint256[] memory milestoneDueDates,
        uint256[] memory milestoneAmounts,
        address paymentToken,
        uint256 totalAmount
    ) internal returns (uint256) {
        if (provider == address(0) || provider == msg.sender) revert InvalidProvider();
        if (totalAmount == 0) revert PaymentRequired();
        if (milestoneDueDates.length != milestoneAmounts.length) revert ArrayLengthMismatch();
        if (milestoneDueDates.length > MAX_MILESTONES) revert TooManyMilestones();

        if (paymentToken != address(0)) {
            if (!whitelistedTokens[paymentToken]) revert TokenNotWhitelisted();
            if (msg.value > 0) revert EthNotAcceptedForTokenPayments();
            IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), totalAmount);
        } else {
            if (msg.value != totalAmount) revert IncorrectPaymentAmount();
        }

        uint256 agreementId = agreementCount++;
        Agreement storage agreement = agreements[agreementId];
        
        agreement.client = msg.sender;
        agreement.provider = provider;
        agreement.totalAmount = uint128(totalAmount);
        agreement.remainingAmount = uint128(totalAmount);
        agreement.deadline = uint64(deadline);
        agreement.terms = terms;
        agreement.paymentToken = paymentToken;
        agreement.createdAt = uint64(block.timestamp);

        for(uint256 i = 0; i < milestoneDueDates.length; i++) {
            agreement.milestones.push(Milestone({
                deadline: uint64(milestoneDueDates[i]),
                amount: uint128(milestoneAmounts[i]),
                completed: false,
                paid: false,
                partiallyCompleted: false,
                completionPercentage: 0,
                evidenceHash: ""
            }));
        }

        userAgreements[msg.sender].push(agreementId);
        userAgreements[provider].push(agreementId);

        emit AgreementCreated(
            agreementId,
            msg.sender,
            provider,
            totalAmount,
            milestoneDueDates.length,
            paymentToken,
            terms
        );

        return agreementId;
    }

    /**
     * @notice Submits evidence for milestone completion
     * @dev Provider submits IPFS hash of evidence for a milestone
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone
     * @param evidenceHash IPFS hash of the evidence
     */
    function submitMilestoneEvidence(
        uint256 agreementId, 
        uint256 milestoneIndex, 
        string calldata evidenceHash
    ) 
        external 
        onlyProvider(agreementId)
        validAgreement(agreementId)
        notCancelled(agreementId)
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert AgreementDisputed();
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestone();
        if (bytes(evidenceHash).length == 0) revert EmptyEvidenceHash();

        Milestone storage milestone = agreement.milestones[milestoneIndex];
        if (milestone.completed) revert MilestoneCompleted();
        if (block.timestamp > milestone.deadline) revert InvalidDeadline();

        milestone.evidenceHash = evidenceHash;
        emit MilestoneEvidenceSubmitted(agreementId, milestoneIndex, evidenceHash);
    }

    /**
     * @notice Marks a milestone as completed
     * @dev Only the client can mark a milestone as completed
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone to complete
     */
    function completeMilestone(uint256 agreementId, uint256 milestoneIndex) 
        external 
        onlyClient(agreementId)
        validAgreement(agreementId)
        notCancelled(agreementId)
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert AgreementDisputed();
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestone();

        Milestone storage milestone = agreement.milestones[milestoneIndex];
        if (milestone.completed) revert MilestoneCompleted();
        if (bytes(milestone.evidenceHash).length == 0) revert NoEvidenceSubmitted();

        milestone.completed = true;
        
        bool allCompleted = true;
        for(uint256 i = 0; i < agreement.milestones.length; i++) {
            if (!agreement.milestones[i].completed) {
                allCompleted = false;
                break;
            }
        }
        
        if (allCompleted) {
            agreement.completed = true;
        }

        emit MilestoneCompleted(agreementId, milestoneIndex, block.timestamp);
    }

    /**
     * @notice Releases payment for a completed milestone
     * @dev Only the client can release payment
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone
     */
    function releaseMilestonePayment(uint256 agreementId, uint256 milestoneIndex) 
        external 
        onlyClient(agreementId) 
        validAgreement(agreementId)
        notCancelled(agreementId)
        nonReentrant 
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert AgreementDisputed();
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestone();

        Milestone storage milestone = agreement.milestones[milestoneIndex];
        if (!milestone.completed) revert MilestoneNotCompleted();
        if (milestone.paid) revert MilestoneAlreadyPaid();

        uint256 paymentAmount = milestone.amount;
        uint256 fee = (paymentAmount * PLATFORM_FEE_PERCENTAGE) / BASIS_POINTS;
        uint256 providerPayment = paymentAmount - fee;

        agreement.remainingAmount -= uint128(paymentAmount);
        milestone.paid = true;

        if (agreement.teamMembers.length > 0) {
            _distributeTeamPayment(agreement, providerPayment);
        } else {
            if (agreement.paymentToken == address(0)) {
                (bool successProvider, ) = payable(agreement.provider).call{value: providerPayment}("");
                if (!successProvider) revert PaymentFailed();
            } else {
                IERC20(agreement.paymentToken).safeTransfer(agreement.provider, providerPayment);
            }
        }

        // Transfer fee
        if (agreement.paymentToken == address(0)) {
            (bool successFee, ) = payable(feeCollector).call{value: fee}("");
            if (!successFee) revert PaymentFailed();
        } else {
            IERC20(agreement.paymentToken).safeTransfer(feeCollector, fee);
        }

        emit PaymentReleased(agreementId, milestoneIndex, providerPayment, fee);
    }

    /**
     * @notice Cancels an agreement
     * @dev Can be called by either client or provider under certain conditions
     * @param agreementId The ID of the agreement to cancel
     * @param reason The reason for cancellation
     */
    function cancelAgreement(uint256 agreementId, string calldata reason)
        external
        onlyParticipant(agreementId)
        validAgreement(agreementId)
        notCancelled(agreementId)
        whenNotPaused
    {
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert AgreementDisputed();
        if (agreement.completed) revert AgreementCompleted();
        
        // Only allow cancellation within timeframe if no milestones are completed
        bool hasCompletedMilestones = false;
        for(uint256 i = 0; i < agreement.milestones.length; i++) {
            if (agreement.milestones[i].completed) {
                hasCompletedMilestones = true;
                break;
            }
        }

        if (hasCompletedMilestones) {
            if (msg.sender != agreement.client || 
                block.timestamp > agreement.createdAt + CANCELLATION_TIMEFRAME) {
                revert CancellationPeriodExpired();
            }
        }

        agreement.cancelled = true;

        // Return remaining funds to client
        if (agreement.remainingAmount > 0) {
            uint256 refundAmount = agreement.remainingAmount;
            agreement.remainingAmount = 0;

            if (agreement.paymentToken == address(0)) {
                (bool success, ) = payable(agreement.client).call{value: refundAmount}("");
                if (!success) revert PaymentFailed();
            } else {
                IERC20(agreement.paymentToken).safeTransfer(agreement.client, refundAmount);
            }
        }

        emit AgreementCancelled(agreementId, msg.sender, reason);
    }

    /**
     * @notice Raises a dispute for an agreement
     * @dev Can be called by either client or provider
     * @param agreementId The ID of the agreement
     * @param reason The reason for the dispute
     */
    function raiseDispute(uint256 agreementId, string calldata reason) 
        external 
        onlyParticipant(agreementId) 
        validAgreement(agreementId)
        notCancelled(agreementId)
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert DisputeAlreadyRaised();
        if (agreement.completed) revert AgreementCompleted();
        if (agreement.remainingAmount == 0) revert InvalidAmount();

        agreement.disputed = true;
        emit DisputeRaised(agreementId, msg.sender, reason);
    }

    /**
     * @notice Resolves a dispute
     * @dev Can only be called by an arbitrator
     * @param agreementId The ID of the disputed agreement
     * @param winner The address of the winning party
     * @param milestonePayouts Array of payout amounts for each milestone
     */
    function resolveDispute(
        uint256 agreementId, 
        address winner,
        uint256[] calldata milestonePayouts
    ) 
        external 
        onlyArbitratorPool
        validAgreement(agreementId) 
        nonReentrant 
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        if (!agreement.disputed) revert AgreementNotDisputed();
        if (winner != agreement.client && winner != agreement.provider) revert InvalidAddress();
        if (milestonePayouts.length != agreement.milestones.length) revert ArrayLengthMismatch();

        uint256 totalPayout = 0;
        for(uint256 i = 0; i < milestonePayouts.length; i++) {
            totalPayout += milestonePayouts[i];
        }
        if (totalPayout > agreement.remainingAmount) revert InsufficientRemainingFunds();

        agreement.disputed = false;
        agreement.completed = true;
        
        uint256 remainingAmount = agreement.remainingAmount;
        agreement.remainingAmount = 0;

        // Handle payouts according to arbitrator's decision
        for(uint256 i = 0; i < milestonePayouts.length; i++) {
            if (milestonePayouts[i] > 0) {
                if (agreement.paymentToken == address(0)) {
                    (bool success, ) = payable(agreement.provider).call{value: milestonePayouts[i]}("");
                    if (!success) revert PaymentFailed();
                } else {
                    IERC20(agreement.paymentToken).safeTransfer(agreement.provider, milestonePayouts[i]);
                }
            }
        }

        // Return remaining funds to client
        uint256 clientRefund = remainingAmount - totalPayout;
        if (clientRefund > 0) {
            if (agreement.paymentToken == address(0)) {
                (bool success, ) = payable(agreement.client).call{value: clientRefund}("");
                if (!success) revert PaymentFailed();
            } else {
                IERC20(agreement.paymentToken).safeTransfer(agreement.client, clientRefund);
            }
        }

        emit DisputeResolved(agreementId, winner);
    }

    /**
     * @notice Submits a rating for a participant
     * @dev Can be called by either client or provider to rate the other party
     * @param agreementId The ID of the completed agreement
     * @param rated The address of the party being rated
     * @param score The rating score (1-5)
     */
    function submitRating(
        uint256 agreementId, 
        address rated, 
        uint256 score
    ) 
        external 
        onlyParticipant(agreementId)
        validAgreement(agreementId)
        onlyUnrated(agreementId)
    {
        if (score < MIN_RATING || score > MAX_RATING) revert InvalidRating();
        
        Agreement storage agreement = agreements[agreementId];
        if (!agreement.completed) revert AgreementNotCompleted();
        if (rated != agreement.client && rated != agreement.provider) revert InvalidAddress();
        if (rated == msg.sender) revert CannotRateSelf();

        agreement.hasRated[msg.sender] = true;
        Rating storage rating = ratings[rated];
        
        rating.total += score;
        rating.count += 1;
        rating.totalTransactionValue += agreement.totalAmount;
        
        // Calculate weighted score
        uint256 prevWeightedValue = rating.weightedScore * (rating.count - 1);
        uint256 newWeightedValue = score * agreement.totalAmount;
        rating.weightedScore = (prevWeightedValue + newWeightedValue) / rating.totalTransactionValue;

        emit RatingSubmitted(agreementId, msg.sender, rated, score);
    }

    // Admin functions
    function setArbitrator(address _newArbitrator) external onlyOwner {
        bytes memory data = abi.encode(_newArbitrator);
        scheduleAction(ACTION_SET_ARBITRATOR, data);
    }

    function setFeeCollector(address _newCollector) external onlyOwner {
        bytes memory data = abi.encode(_newCollector);
        scheduleAction(ACTION_SET_FEE_COLLECTOR, data);
    }

    function addWhitelistedToken(address token) external onlyOwner {
        bytes memory data = abi.encode(token);
        scheduleAction(ACTION_WHITELIST_TOKEN, data);
    }

    function removeWhitelistedToken(address token) external onlyOwner {
        bytes memory data = abi.encode(token);
        scheduleAction(ACTION_REMOVE_TOKEN, data);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Extends the deadline for a milestone
     * @dev Can be called by either client or provider
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone
     * @param newDeadline The new deadline timestamp
     */
    function extendMilestoneDeadline(
        uint256 agreementId,
        uint256 milestoneIndex,
        uint256 newDeadline
    ) 
        external 
        onlyParticipant(agreementId) 
        validAgreement(agreementId)
        notCancelled(agreementId)
    {
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert AgreementDisputed();
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestone();
        if (newDeadline <= block.timestamp) revert InvalidDeadline();
        if (newDeadline > agreement.deadline) revert InvalidDeadline();
        
        agreement.milestones[milestoneIndex].deadline = uint64(newDeadline);
        emit MilestoneDeadlineExtended(agreementId, milestoneIndex, newDeadline);
    }

    /**
     * @notice Withdraws funds in case of emergency
     * @dev Can only be called by the contract owner
     * @param token The token address (address(0) for ETH)
     */
    function emergencyWithdraw(address token) external onlyOwner {
        if (token == address(0)) {
            (bool success, ) = payable(owner()).call{value: address(this).balance}("");
            if (!success) revert PaymentFailed();
        } else {
            IERC20 tokenContract = IERC20(token);
            uint256 balance = tokenContract.balanceOf(address(this));
            if (balance == 0) revert NoTokensToWithdraw();
            tokenContract.safeTransfer(owner(), balance);
        }
    }

    // View functions
    /**
     * @notice Gets detailed information about an agreement
     * @dev Returns all main properties of an agreement
     * @param agreementId The ID of the agreement to query
     * @return client The client address
     * @return provider The service provider address
     * @return totalAmount The total payment amount
     * @return remainingAmount The remaining unpaid amount
     * @return deadline The agreement deadline timestamp
     * @return completed Whether the agreement is completed
     * @return disputed Whether the agreement is disputed
     * @return cancelled Whether the agreement is cancelled
     * @return terms The agreement terms
     * @return createdAt The creation timestamp
     * @return paymentToken The payment token address (address(0) for ETH)
     * @return milestoneCount The number of milestones
     */
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
            bool completed,
            bool disputed,
            bool cancelled,
            string memory terms,
            uint256 createdAt,
            address paymentToken,
            uint256 milestoneCount
        ) 
    {
        Agreement storage agreement = agreements[agreementId];
        return (
            agreement.client,
            agreement.provider,
            agreement.totalAmount,
            agreement.remainingAmount,
            agreement.deadline,
            agreement.completed,
            agreement.disputed,
            agreement.cancelled,
            agreement.terms,
            agreement.createdAt,
            agreement.paymentToken,
            agreement.milestones.length
        );
    }

    /**
     * @notice Gets detailed information about a milestone
     * @dev Returns all properties of a specific milestone
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone to query
     * @return deadline The milestone deadline timestamp
     * @return amount The payment amount for this milestone
     * @return completed Whether the milestone is completed
     * @return paid Whether the milestone payment has been released
     * @return evidenceHash IPFS hash of completion evidence
     */
    function getMilestoneDetails(uint256 agreementId, uint256 milestoneIndex)
        external
        view
        validAgreement(agreementId)
        returns (
            uint256 deadline,
            uint256 amount,
            bool completed,
            bool paid,
            string memory evidenceHash
        )
    {
        Agreement storage agreement = agreements[agreementId];
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestoneIndex();
        
        Milestone storage milestone = agreement.milestones[milestoneIndex];
        return (
            milestone.deadline,
            milestone.amount,
            milestone.completed,
            milestone.paid,
            milestone.evidenceHash
        );
    }

    /**
     * @notice Gets all agreements associated with a user
     * @dev Returns array of agreement IDs where the user is client or provider
     * @param user The user address to query
     * @return Array of agreement IDs
     */
    function getUserAgreements(address user) external view returns (uint256[] memory) {
        return userAgreements[user];
    }

    /**
     * @notice Gets the rating information for a user
     * @dev Returns detailed rating statistics
     * @param user The user address to query
     * @return total Sum of all ratings
     * @return count Number of ratings received
     * @return weightedScore Rating score weighted by transaction amounts
     * @return totalTransactionValue Total value of all rated transactions
     */
    function getUserRating(address user) external view returns (
        uint256 total,
        uint256 count,
        uint256 weightedScore,
        uint256 totalTransactionValue
    ) {
        Rating storage rating = ratings[user];
        return (
            rating.total,
            rating.count,
            rating.weightedScore,
            rating.totalTransactionValue
        );
    }

    /**
     * @notice Gets all milestones for an agreement
     * @dev Returns arrays of milestone properties
     * @param agreementId The ID of the agreement
     * @return deadlines Array of milestone deadlines
     * @return amounts Array of milestone payment amounts
     * @return completedStates Array of milestone completion states
     * @return paidStates Array of milestone payment states
     * @return evidenceHashes Array of evidence IPFS hashes
     */
    function getMilestones(uint256 agreementId) 
        external 
        view 
        validAgreement(agreementId)
        returns (
            uint256[] memory deadlines,
            uint256[] memory amounts,
            bool[] memory completedStates,
            bool[] memory paidStates,
            string[] memory evidenceHashes
        )
    {
        Agreement storage agreement = agreements[agreementId];
        uint256 length = agreement.milestones.length;
        
        deadlines = new uint256[](length);
        amounts = new uint256[](length);
        completedStates = new bool[](length);
        paidStates = new bool[](length);
        evidenceHashes = new string[](length);
        
        for(uint256 i = 0; i < length; i++) {
            Milestone storage milestone = agreement.milestones[i];
            deadlines[i] = milestone.deadline;
            amounts[i] = milestone.amount;
            completedStates[i] = milestone.completed;
            paidStates[i] = milestone.paid;
            evidenceHashes[i] = milestone.evidenceHash;
        }
        
        return (deadlines, amounts, completedStates, paidStates, evidenceHashes);
    }

    /**
     * @notice Gets information about a proposed milestone change
     * @dev Returns the proposed changes and approval status
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone
     * @return newDeadline The proposed new deadline
     * @return newAmount The proposed new amount
     * @return clientApproved Whether the client has approved
     * @return providerApproved Whether the provider has approved
     */
    function getProposedMilestoneChange(uint256 agreementId, uint256 milestoneIndex)
        external
        view
        validAgreement(agreementId)
        returns (
            uint256 newDeadline,
            uint256 newAmount,
            bool clientApproved,
            bool providerApproved
        )
    {
        if (milestoneIndex >= agreements[agreementId].milestones.length) revert InvalidMilestoneIndex();
        
        MilestoneChange storage change = proposedMilestoneChanges[agreementId][milestoneIndex];
        return (
            change.newDeadline,
            change.newAmount,
            change.clientApproved,
            change.providerApproved
        );
    }

    /**
     * @notice Gets dispute escalation information
     * @dev Returns the current escalation level and evidence
     * @param agreementId The ID of the agreement
     * @param participant The address of the participant
     * @return level The current escalation level
     * @return evidence The evidence submitted by the participant
     */
    function getDisputeEscalationInfo(uint256 agreementId, address participant)
        external
        view
        validAgreement(agreementId)
        returns (
            uint256 level,
            string memory evidence
        )
    {
        return (
            disputeEscalationLevel[agreementId],
            disputeEvidence[agreementId][participant]
        );
    }

    /**
     * @notice Marks a milestone as partially completed
     * @dev Provider can indicate partial completion with a percentage
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone
     * @param completionPercentage The percentage of completion (1-99)
     */
    function markMilestonePartiallyComplete(
        uint256 agreementId, 
        uint256 milestoneIndex,
        uint8 completionPercentage
    ) 
        external 
        onlyProvider(agreementId)
        validAgreement(agreementId)
        notCancelled(agreementId)
        whenNotPaused 
    {
        if (completionPercentage == 0 || completionPercentage >= 100) revert InvalidPercentage();
        
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert AgreementDisputed();
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestone();

        Milestone storage milestone = agreement.milestones[milestoneIndex];
        if (milestone.completed) revert MilestoneCompleted();
        if (bytes(milestone.evidenceHash).length == 0) revert NoEvidenceSubmitted();

        milestone.partiallyCompleted = true;
        milestone.completionPercentage = completionPercentage;

        emit PartialMilestoneCompleted(agreementId, milestoneIndex, completionPercentage, block.timestamp);
    }

    /**
     * @notice Releases payment for a partially completed milestone
     * @dev Client can pay a percentage of the milestone amount
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone
     */
    function releasePartialMilestonePayment(
        uint256 agreementId, 
        uint256 milestoneIndex
    ) 
        external 
        onlyClient(agreementId) 
        validAgreement(agreementId)
        notCancelled(agreementId)
        nonReentrant 
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert AgreementDisputed();
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestone();

        Milestone storage milestone = agreement.milestones[milestoneIndex];
        if (!milestone.partiallyCompleted) revert MilestoneNotCompleted();
        if (milestone.paid) revert MilestoneAlreadyPaid();

        uint256 paymentAmount = (milestone.amount * milestone.completionPercentage) / 100;
        uint256 fee = (paymentAmount * PLATFORM_FEE_PERCENTAGE) / BASIS_POINTS;
        uint256 providerPayment = paymentAmount - fee;

        agreement.remainingAmount -= uint128(paymentAmount);
        
        // Mark as paid but not completed
        milestone.paid = true;

        // Handle team payments if applicable
        if (agreement.teamMembers.length > 0) {
            _distributeTeamPayment(agreement, providerPayment);
        } else {
            if (agreement.paymentToken == address(0)) {
                (bool successProvider, ) = payable(agreement.provider).call{value: providerPayment}("");
                if (!successProvider) revert PaymentFailed();
            } else {
                IERC20(agreement.paymentToken).safeTransfer(agreement.provider, providerPayment);
            }
        }

        // Transfer fee
        if (agreement.paymentToken == address(0)) {
            (bool successFee, ) = payable(feeCollector).call{value: fee}("");
            if (!successFee) revert PaymentFailed();
        } else {
            IERC20(agreement.paymentToken).safeTransfer(feeCollector, fee);
        }

        emit PaymentReleased(agreementId, milestoneIndex, providerPayment, fee);
    }

    /**
     * @dev Distributes payment among team members according to their shares
     * @param agreement The agreement containing team information
     * @param totalAmount The total amount to distribute
     */
    function _distributeTeamPayment(Agreement storage agreement, uint256 totalAmount) internal {
        uint256 totalShares = 0;
        uint256 teamLength = agreement.teamShares.length;
        
        for (uint i = 0; i < teamLength; i++) {
            totalShares += agreement.teamShares[i];
        }
        
        if (totalShares != BASIS_POINTS) revert SharesMustTotal100Percent();
        
        uint256 distributedAmount = 0;
        uint256 remainingAmount = totalAmount;
        
        // Distribute to all team members except the last one
        uint256 lastIndex = teamLength - 1;
        for (uint i = 0; i < lastIndex; i++) {
            uint256 memberPayment;
            unchecked {
                memberPayment = (totalAmount * agreement.teamShares[i]) / BASIS_POINTS;
                distributedAmount += memberPayment;
                remainingAmount -= memberPayment;
            }
            
            if (agreement.paymentToken == address(0)) {
                (bool success, ) = payable(agreement.teamMembers[i]).call{value: memberPayment}("");
                if (!success) revert PaymentFailed();
            } else {
                IERC20(agreement.paymentToken).safeTransfer(agreement.teamMembers[i], memberPayment);
            }
        }
        
        // Send remaining amount to the last team member to avoid rounding errors
        if (teamLength > 0) {
            address lastMember = agreement.teamMembers[lastIndex];
            
            if (agreement.paymentToken == address(0)) {
                (bool success, ) = payable(lastMember).call{value: remainingAmount}("");
                if (!success) revert PaymentFailed();
            } else {
                IERC20(agreement.paymentToken).safeTransfer(lastMember, remainingAmount);
            }
        }
    }

    // New function to add team members
    function addTeamMembers(
        uint256 agreementId,
        address[] calldata members,
        uint256[] calldata shares
    )
        external
        onlyProvider(agreementId)
        validAgreement(agreementId)
        notCancelled(agreementId)
    {
        if (members.length != shares.length) revert ArrayLengthMismatch();
        if (members.length == 0) revert NoMembersProvided();
        
        Agreement storage agreement = agreements[agreementId];
        if (agreement.teamMembers.length > 0) revert TeamAlreadySet();
        
        uint256 totalShares = 0;
        for (uint i = 0; i < shares.length; i++) {
            if (members[i] == address(0)) revert InvalidAddress();
            totalShares += shares[i];
            agreement.teamMembers.push(members[i]);
            agreement.teamShares.push(shares[i]);
            
            // Add agreement to team member's list
            userAgreements[members[i]].push(agreementId);
            
            emit TeamMemberAdded(agreementId, members[i], shares[i]);
        }
        
        if (totalShares != BASIS_POINTS) revert SharesMustTotal100Percent();
    }

    // Update to multi-arbitrator pool
    function setArbitratorPool(address[] calldata _arbitrators) external onlyOwner {
        if (_arbitrators.length == 0) revert EmptyArbitratorPool();
        
        // Clear existing pool
        delete arbitratorPool;
        
        // Add new arbitrators
        for (uint i = 0; i < _arbitrators.length; i++) {
            if (_arbitrators[i] == address(0)) revert InvalidAddress();
            arbitratorPool.push(_arbitrators[i]);
        }
        
        // Set primary arbitrator
        arbitrator = _arbitrators[0];
        
        emit ArbitratorPoolUpdated(_arbitrators);
    }

    // Batch operations for gas efficiency
    function batchCompleteMilestones(uint256 agreementId, uint256[] calldata milestoneIndices) 
        external 
        onlyClient(agreementId)
        validAgreement(agreementId)
        notCancelled(agreementId)
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert AgreementDisputed();
        
        uint256 milestoneCount = agreement.milestones.length;
        
        for (uint i = 0; i < milestoneIndices.length; i++) {
            uint256 milestoneIndex = milestoneIndices[i];
            if (milestoneIndex >= milestoneCount) revert InvalidMilestone();

            Milestone storage milestone = agreement.milestones[milestoneIndex];
            if (milestone.completed) revert MilestoneCompleted();
            if (bytes(milestone.evidenceHash).length == 0) revert NoEvidenceSubmitted();

            milestone.completed = true;
            
            emit MilestoneCompleted(agreementId, milestoneIndex, block.timestamp);
        }
        
        // Check if all milestones are completed
        bool allCompleted = true;
        for(uint256 i = 0; i < milestoneCount; i++) {
            if (!agreement.milestones[i].completed) {
                allCompleted = false;
                break;
            }
        }
        
        if (allCompleted) {
            agreement.completed = true;
        }
    }

    // Batch payment release for gas efficiency
    function batchReleaseMilestonePayments(uint256 agreementId, uint256[] calldata milestoneIndices) 
        external 
        onlyClient(agreementId) 
        validAgreement(agreementId)
        notCancelled(agreementId)
        nonReentrant 
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        require(!agreement.disputed, "Agreement is disputed");
        
        uint256 totalPaymentAmount = 0;
        uint256 totalFee = 0;
        
        for (uint i = 0; i < milestoneIndices.length; i++) {
            uint256 milestoneIndex = milestoneIndices[i];
            require(milestoneIndex < agreement.milestones.length, "Invalid milestone");

            Milestone storage milestone = agreement.milestones[milestoneIndex];
            require(milestone.completed, "Milestone not completed");
            require(!milestone.paid, "Payment already released");

            uint256 paymentAmount = milestone.amount;
            uint256 fee = (paymentAmount * PLATFORM_FEE_PERCENTAGE) / BASIS_POINTS;
            
            totalPaymentAmount += (paymentAmount - fee);
            totalFee += fee;
            
            milestone.paid = true;
        }
        
        agreement.remainingAmount -= (totalPaymentAmount + totalFee);
        
        // Handle team payments if applicable
        if (agreement.teamMembers.length > 0) {
            _distributeTeamPayment(agreement, totalPaymentAmount);
        } else {
            if (agreement.paymentToken == address(0)) {
                (bool successProvider, ) = payable(agreement.provider).call{value: totalPaymentAmount}("");
                require(successProvider, "Provider payment failed");
            } else {
                IERC20(agreement.paymentToken).safeTransfer(agreement.provider, totalPaymentAmount);
            }
        }
        
        // Transfer fee
        if (agreement.paymentToken == address(0)) {
            (bool successFee, ) = payable(feeCollector).call{value: totalFee}("");
            require(successFee, "Fee transfer failed");
        } else {
            IERC20(agreement.paymentToken).safeTransfer(feeCollector, totalFee);
        }
        
        for (uint i = 0; i < milestoneIndices.length; i++) {
            // Include actual payment amounts in individual events for better tracking
            uint256 milestoneIndex = milestoneIndices[i];
            uint256 milestoneAmount = agreement.milestones[milestoneIndex].amount;
            uint256 milestoneFee = (milestoneAmount * PLATFORM_FEE_PERCENTAGE) / BASIS_POINTS;
            uint256 milestonePayment = milestoneAmount - milestoneFee;
            
            emit PaymentReleased(agreementId, milestoneIndices[i], milestonePayment, milestoneFee);
        }
        
        // Emit a batch event
        emit BatchPaymentReleased(agreementId, milestoneIndices, totalPaymentAmount, totalFee);
    }

    // New event for batch operations
    event BatchPaymentReleased(uint256 indexed id, uint256[] milestones, uint256 totalAmount, uint256 totalFee);

    // Schedule an action
    function scheduleAction(bytes32 actionType, bytes calldata data) external onlyOwner returns (bytes32) {
        bytes32 actionId = keccak256(abi.encodePacked(actionType, data, block.timestamp));
        pendingActions[actionId] = PendingAction({
            actionType: actionType,
            data: data,
            timestamp: block.timestamp,
            executed: false
        });
        
        emit ActionScheduled(actionId, actionType, data, block.timestamp + TIMELOCK_DURATION);
        return actionId;
    }
    
    // Execute a scheduled action
    function executeAction(bytes32 actionId) external onlyOwner {
        PendingAction storage action = pendingActions[actionId];
        
        if (action.timestamp == 0) revert AgreementNotFound();
        if (action.executed) revert AgreementCompleted();
        if (block.timestamp < action.timestamp + TIMELOCK_DURATION) revert InvalidDeadline();
        
        action.executed = true;
        
        if (action.actionType == ACTION_SET_ARBITRATOR) {
            address newArbitrator = abi.decode(action.data, (address));
            _setArbitrator(newArbitrator);
        } else if (action.actionType == ACTION_SET_FEE_COLLECTOR) {
            address newCollector = abi.decode(action.data, (address));
            _setFeeCollector(newCollector);
        } else if (action.actionType == ACTION_WHITELIST_TOKEN) {
            address token = abi.decode(action.data, (address));
            _addWhitelistedToken(token);
        } else if (action.actionType == ACTION_REMOVE_TOKEN) {
            address token = abi.decode(action.data, (address));
            _removeWhitelistedToken(token);
        }
        
        emit ActionExecuted(actionId);
    }
    
    // Cancel a scheduled action
    function cancelAction(bytes32 actionId) external onlyOwner {
        PendingAction storage action = pendingActions[actionId];
        
        if (action.timestamp == 0) revert AgreementNotFound();
        if (action.executed) revert AgreementCompleted();
        
        delete pendingActions[actionId];
        
        emit ActionCancelled(actionId);
    }
    
    // Internal functions for actions
    function _setArbitrator(address _newArbitrator) internal {
        if (_newArbitrator == address(0)) revert InvalidAddress();
        address oldArbitrator = arbitrator;
        arbitrator = _newArbitrator;
        emit ArbitratorUpdated(oldArbitrator, _newArbitrator);
    }
    
    function _setFeeCollector(address _newCollector) internal {
        if (_newCollector == address(0)) revert InvalidAddress();
        address oldCollector = feeCollector;
        feeCollector = _newCollector;
        emit FeeCollectorUpdated(oldCollector, _newCollector);
    }
    
    function _addWhitelistedToken(address token) internal {
        if (token == address(0)) revert InvalidAddress();
        whitelistedTokens[token] = true;
        emit TokenWhitelisted(token, true);
    }
    
    function _removeWhitelistedToken(address token) internal {
        whitelistedTokens[token] = false;
        emit TokenWhitelisted(token, false);
    }

    /**
     * @notice Escalates a dispute to the next level of arbitration
     * @dev Can only be called by a participant after the initial dispute period
     * @param agreementId The ID of the disputed agreement
     * @param reason Reason for escalation
     * @param evidence IPFS hash of supporting evidence
     */
    function escalateDispute(
        uint256 agreementId,
        string calldata reason,
        string calldata evidence
    ) 
        external 
        onlyParticipant(agreementId)
        validAgreement(agreementId)
        whenNotPaused
    {
        Agreement storage agreement = agreements[agreementId];
        if (!agreement.disputed) revert AgreementNotDisputed();
        
        uint256 currentLevel = disputeEscalationLevel[agreementId];
        if (currentLevel >= arbitratorPool.length - 1) revert MaxEscalationReached();
        
        // Ensure minimum time has passed since last escalation
        uint256 disputeTime = block.timestamp - agreement.createdAt;
        if (disputeTime < ESCALATION_PERIOD * (currentLevel + 1)) revert EscalationPeriodNotMet();
        
        // Store evidence and increment escalation level
        disputeEvidence[agreementId][msg.sender] = evidence;
        disputeEscalationLevel[agreementId] = currentLevel + 1;
        
        emit DisputeEscalated(agreementId, msg.sender, currentLevel + 1, reason);
    }

    /**
     * @notice Proposes changes to a milestone
     * @dev Can be initiated by either client or provider
     * @param agreementId The agreement ID
     * @param milestoneIndex The milestone to modify
     * @param newDeadline The proposed new deadline
     * @param newAmount The proposed new payment amount
     */
    function proposeMilestoneChange(
        uint256 agreementId,
        uint256 milestoneIndex,
        uint256 newDeadline,
        uint256 newAmount
    )
        external
        onlyParticipant(agreementId)
        validAgreement(agreementId)
        notCancelled(agreementId)
        whenNotPaused
    {
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert AgreementDisputed();
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestone();
        
        Milestone storage milestone = agreement.milestones[milestoneIndex];
        if (milestone.completed) revert MilestoneCompleted();
        if (milestone.paid) revert MilestoneAlreadyPaid();
        if (newDeadline <= block.timestamp) revert InvalidDeadline();
        
        MilestoneChange storage change = proposedMilestoneChanges[agreementId][milestoneIndex];
        change.newDeadline = uint64(newDeadline);
        change.newAmount = uint128(newAmount);
        
        // Auto-approve for the proposer
        if (msg.sender == agreement.client) {
            change.clientApproved = true;
        } else {
            change.providerApproved = true;
        }
        
        emit MilestoneChangeProposed(agreementId, milestoneIndex, msg.sender, newDeadline, newAmount);
    }

    /**
     * @notice Approves a proposed milestone change
     * @dev The counterparty approves changes proposed by the other party
     * @param agreementId The agreement ID
     * @param milestoneIndex The milestone index
     */
    function approveMilestoneChange(
        uint256 agreementId,
        uint256 milestoneIndex
    )
        external
        onlyParticipant(agreementId)
        validAgreement(agreementId)
        notCancelled(agreementId)
        whenNotPaused
    {
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert AgreementDisputed();
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestone();
        
        MilestoneChange storage change = proposedMilestoneChanges[agreementId][milestoneIndex];
        if (change.newDeadline == 0) revert NoProposedChange();
        
        // Set approval flag for the approver
        if (msg.sender == agreement.client) {
            if (change.clientApproved) revert ChangeAlreadyApproved();
            change.clientApproved = true;
        } else if (msg.sender == agreement.provider) {
            if (change.providerApproved) revert ChangeAlreadyApproved();
            change.providerApproved = true;
        }
        
        // If both parties approved, apply the change
        if (change.clientApproved && change.providerApproved) {
            Milestone storage milestone = agreement.milestones[milestoneIndex];
            
            // Calculate the difference in amount
            int256 amountDifference = int256(uint256(change.newAmount)) - int256(uint256(milestone.amount));
            
            // Update milestone
            milestone.deadline = change.newDeadline;
            milestone.amount = change.newAmount;
            
            // Adjust agreement total and remaining amount
            if (amountDifference > 0) {
                // Handle additional payment if amount increased
                uint256 additionalAmount = uint256(amountDifference);
                agreement.totalAmount += uint128(additionalAmount);
                agreement.remainingAmount += uint128(additionalAmount);
                
                // Transfer additional funds from client
                if (agreement.paymentToken == address(0)) {
                    if (msg.value != additionalAmount) revert IncorrectPaymentAmount();
                } else {
                    IERC20(agreement.paymentToken).safeTransferFrom(
                        agreement.client, 
                        address(this), 
                        additionalAmount
                    );
                }
            } else if (amountDifference < 0) {
                // Handle refund if amount decreased
                uint256 refundAmount = uint256(-amountDifference);
                agreement.totalAmount -= uint128(refundAmount);
                agreement.remainingAmount -= uint128(refundAmount);
                
                // Refund client
                if (agreement.paymentToken == address(0)) {
                    (bool success, ) = payable(agreement.client).call{value: refundAmount}("");
                    if (!success) revert PaymentFailed();
                } else {
                    IERC20(agreement.paymentToken).safeTransfer(agreement.client, refundAmount);
                }
            }
            
            // Clear the proposed change
            delete proposedMilestoneChanges[agreementId][milestoneIndex];
            
            emit MilestoneChanged(
                agreementId, 
                milestoneIndex, 
                change.newDeadline, 
                change.newAmount
            );
        } else {
            emit MilestoneChangeApproved(agreementId, milestoneIndex, msg.sender);
        }
    }
}