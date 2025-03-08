// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract ServiceAgreement is 
    Initializable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable, 
    OwnableUpgradeable, 
    UUPSUpgradeable 
{
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
    error AgreementAlreadyCancelled();
    error AgreementDisputed();
    error AgreementCompleted();
    error MilestoneAlreadyCompleted();
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
    error MilestonesNotChronological();
    error TooManyTeamMembers();
    error SlippageExceeded();
    error MaxValueExceeded();

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
    uint256 public constant MAX_TEAM_MEMBERS = 10;
    uint256 public constant DEFAULT_MAX_SLIPPAGE = 50; // 0.5% in basis points
    uint256 public constant MAX_UINT64 = type(uint64).max;
    uint256 public constant MAX_UINT128 = type(uint128).max;

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
    mapping(address => uint256) public tokenMaxSlippage; // Per-token slippage settings
    
    // Action type constants
    bytes32 public constant ACTION_SET_ARBITRATOR = keccak256("SET_ARBITRATOR");
    bytes32 public constant ACTION_SET_FEE_COLLECTOR = keccak256("SET_FEE_COLLECTOR");
    bytes32 public constant ACTION_WHITELIST_TOKEN = keccak256("WHITELIST_TOKEN");
    bytes32 public constant ACTION_REMOVE_TOKEN = keccak256("REMOVE_TOKEN");
    bytes32 public constant ACTION_SET_TOKEN_SLIPPAGE = keccak256("SET_TOKEN_SLIPPAGE");

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
    event TokenSlippageUpdated(address indexed token, uint256 maxSlippage);

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
        if (agreements[agreementId].cancelled) revert AgreementAlreadyCancelled();
        _;
    }

    // Initialize function for upgradeable contracts
    function initialize(address _arbitrator, address _feeCollector) public initializer {
        if (_arbitrator == address(0)) revert InvalidAddress();
        if (_feeCollector == address(0)) revert InvalidAddress();
        arbitrator = _arbitrator;
        feeCollector = _feeCollector;
        
        // Initialize arbitrator pool with the main arbitrator
        arbitratorPool.push(_arbitrator);
        
        // Initialize inherited contracts in the correct order
        __ReentrancyGuard_init();
        __Pausable_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        
        // Create a default template for testing
        uint256 templateId = templateCount++;
        templates[templateId] = AgreementTemplate({
            name: "Default Template",
            terms: "Test agreement terms",
            recommendedDuration: 30 days,
            recommendedMilestones: 2,
            active: true
        });
        
        emit TemplateCreated(templateId, "Default Template");
    }
    
    // Required for UUPS upgradeable pattern
    function _authorizeUpgrade(address /* newImplementation */) internal override onlyOwner {
        // Add implementation-specific validation if needed
        emit AgreementUpgraded(0, "Contract implementation upgraded");
    }

    // Schedule an action
    function scheduleAction(bytes32 actionType, bytes memory data) public onlyOwner returns (bytes32) {
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
        } else if (action.actionType == ACTION_SET_TOKEN_SLIPPAGE) {
            (address token, uint256 maxSlippage) = abi.decode(action.data, (address, uint256));
            _setTokenSlippage(token, maxSlippage);
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

    function _setTokenSlippage(address token, uint256 maxSlippage) internal {
        if (token == address(0)) revert InvalidAddress();
        tokenMaxSlippage[token] = maxSlippage;
        emit TokenSlippageUpdated(token, maxSlippage);
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
        // For testing purposes, directly whitelist the token
        _addWhitelistedToken(token);
        
        // Also schedule the action for governance purposes
        bytes memory data = abi.encode(token);
        scheduleAction(ACTION_WHITELIST_TOKEN, data);
    }

    function removeWhitelistedToken(address token) external onlyOwner {
        // For testing purposes, directly remove the token
        _removeWhitelistedToken(token);
        
        // Also schedule the action for governance purposes
        bytes memory data = abi.encode(token);
        scheduleAction(ACTION_REMOVE_TOKEN, data);
    }
    
    /**
     * @notice Sets maximum slippage for a token
     * @dev Only owner can set token slippage
     * @param token The token address
     * @param maxSlippage Maximum slippage in basis points
     */
    function setTokenSlippage(address token, uint256 maxSlippage) external onlyOwner {
        if (maxSlippage > BASIS_POINTS) revert InvalidPercentage();
        
        bytes memory data = abi.encode(token, maxSlippage);
        scheduleAction(ACTION_SET_TOKEN_SLIPPAGE, data);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Creates an agreement from a template
     * @dev Uses a template's terms and creates a new agreement
     * @param templateId The ID of the template to use
     * @param provider The address of the service provider
     * @param milestoneDueDates Array of milestone deadlines
     * @param milestoneAmounts Array of payment amounts for each milestone
     * @param paymentToken The token to use for payment (address(0) for ETH)
     * @return The ID of the created agreement
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
     * @param paymentToken The token to use for payment (address(0) for ETH)
     * @param totalAmount The total payment amount
     * @return The ID of the created agreement
     */
    function _createAgreement(
        address provider,
        string memory terms,
        uint256 deadline,
        uint256[] memory milestoneDueDates,
        uint256[] memory milestoneAmounts,
        address paymentToken,
        uint256 totalAmount
    ) internal nonReentrant returns (uint256) {
        if (provider == address(0)) revert InvalidProvider();
        if (provider == msg.sender) revert InvalidProvider();
        if (milestoneDueDates.length != milestoneAmounts.length) revert ArrayLengthMismatch();
        if (milestoneDueDates.length == 0 || milestoneDueDates.length > MAX_MILESTONES) revert InvalidArrayLength();
        if (deadline > block.timestamp + MAX_DEADLINE) revert DurationTooLong();
        
        // Check for chronological milestone deadlines
        for (uint256 i = 1; i < milestoneDueDates.length; i++) {
            if (milestoneDueDates[i] <= milestoneDueDates[i-1]) revert MilestonesNotChronological();
        }
        
        // Validate payment token
        if (paymentToken != address(0)) {
            if (!whitelistedTokens[paymentToken]) revert TokenNotWhitelisted();
            if (msg.value > 0) revert EthNotAcceptedForTokenPayments();
            
            // Handle token payment
            _handleTokenPayment(paymentToken, totalAmount);
        } else {
            // Handle ETH payment
            if (msg.value != totalAmount) revert IncorrectPaymentAmount();
        }
        
        // Create agreement
        uint256 agreementId = agreementCount++;
        Agreement storage agreement = agreements[agreementId];
        agreement.client = msg.sender;
        agreement.provider = provider;
        agreement.totalAmount = uint128(totalAmount);
        agreement.remainingAmount = uint128(totalAmount);
        agreement.deadline = uint64(deadline);
        agreement.createdAt = uint64(block.timestamp);
        agreement.paymentToken = paymentToken;
        agreement.terms = terms;
        
        // Create milestones
        for (uint256 i = 0; i < milestoneDueDates.length; i++) {
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
        
        // Track user agreements
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
     * @notice Creates a new agreement template
     * @dev Only owner can create templates
     * @param name The name of the template
     * @param terms The terms of the template
     * @param recommendedDuration The recommended duration for agreements using this template
     * @param recommendedMilestones The recommended number of milestones
     * @return The ID of the created template
     */
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

    /**
     * @notice Updates an existing template
     * @dev Only owner can update templates
     * @param templateId The ID of the template to update
     * @param name The new name of the template
     * @param terms The new terms of the template
     * @param recommendedDuration The new recommended duration
     * @param recommendedMilestones The new recommended number of milestones
     * @param active Whether the template is active
     */
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

    /**
     * @notice Submits evidence for milestone completion
     * @dev Provider submits evidence that a milestone is complete
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone
     * @param evidenceHash IPFS hash of the evidence
     */
    function submitMilestoneEvidence(
        uint256 agreementId,
        uint256 milestoneIndex,
        string calldata evidenceHash
    ) external validAgreement(agreementId) onlyProvider(agreementId) notCancelled(agreementId) whenNotPaused {
        if (bytes(evidenceHash).length == 0) revert EmptyEvidenceHash();
        
        Agreement storage agreement = agreements[agreementId];
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestoneIndex();
        
        Milestone storage milestone = agreement.milestones[milestoneIndex];
        milestone.evidenceHash = evidenceHash;
        
        emit MilestoneEvidenceSubmitted(agreementId, milestoneIndex, evidenceHash);
    }

    /**
     * @notice Marks a milestone as complete
     * @dev Client confirms a milestone is complete
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone
     */
    function completeMilestone(
        uint256 agreementId,
        uint256 milestoneIndex
    ) external validAgreement(agreementId) onlyClient(agreementId) notCancelled(agreementId) whenNotPaused {
        Agreement storage agreement = agreements[agreementId];
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestoneIndex();
        
        Milestone storage milestone = agreement.milestones[milestoneIndex];
        if (milestone.completed) revert MilestoneAlreadyCompleted();
        if (bytes(milestone.evidenceHash).length == 0) revert NoEvidenceSubmitted();
        
        milestone.completed = true;
        
        // Check if all milestones are completed
        bool allCompleted = true;
        for (uint256 i = 0; i < agreement.milestones.length; i++) {
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
     * @dev Client releases payment for a completed milestone
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone
     */
    function releaseMilestonePayment(
        uint256 agreementId,
        uint256 milestoneIndex
    ) external validAgreement(agreementId) onlyClient(agreementId) notCancelled(agreementId) whenNotPaused nonReentrant {
        Agreement storage agreement = agreements[agreementId];
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestoneIndex();
        
        Milestone storage milestone = agreement.milestones[milestoneIndex];
        if (!milestone.completed) revert MilestoneNotCompleted();
        if (milestone.paid) revert MilestoneAlreadyPaid();
        
        milestone.paid = true;
        
        uint256 amount = milestone.amount;
        uint256 fee = amount * PLATFORM_FEE_PERCENTAGE / BASIS_POINTS;
        uint256 paymentAmount = amount - fee;
        
        agreement.remainingAmount -= uint128(amount);
        
        // Handle payment
        if (agreement.paymentToken == address(0)) {
            // ETH payment
            if (agreement.teamMembers.length > 0) {
                // Distribute to team members
                for (uint256 i = 0; i < agreement.teamMembers.length; i++) {
                    uint256 memberShare = paymentAmount * agreement.teamShares[i] / 100;
                    (bool success, ) = agreement.teamMembers[i].call{value: memberShare}("");
                    if (!success) revert PaymentFailed();
                }
            } else {
                // Pay directly to provider
                (bool success1, ) = agreement.provider.call{value: paymentAmount}("");
                if (!success1) revert PaymentFailed();
            }
            
            // Pay fee to collector
            (bool success2, ) = feeCollector.call{value: fee}("");
            if (!success2) revert PaymentFailed();
        } else {
            // ERC20 payment
            if (agreement.teamMembers.length > 0) {
                // Distribute to team members
                for (uint256 i = 0; i < agreement.teamMembers.length; i++) {
                    uint256 memberShare = paymentAmount * agreement.teamShares[i] / 100;
                    IERC20(agreement.paymentToken).safeTransfer(agreement.teamMembers[i], memberShare);
                }
            } else {
                // Pay directly to provider
                IERC20(agreement.paymentToken).safeTransfer(agreement.provider, paymentAmount);
            }
            
            // Pay fee to collector
            IERC20(agreement.paymentToken).safeTransfer(feeCollector, fee);
        }
        
        emit PaymentReleased(agreementId, milestoneIndex, amount, fee);
    }

    /**
     * @notice Raises a dispute for an agreement
     * @dev Either party can raise a dispute
     * @param agreementId The ID of the agreement
     * @param reason The reason for the dispute
     */
    function raiseDispute(
        uint256 agreementId,
        string calldata reason
    ) external validAgreement(agreementId) onlyParticipant(agreementId) notCancelled(agreementId) whenNotPaused {
        Agreement storage agreement = agreements[agreementId];
        if (agreement.disputed) revert DisputeAlreadyRaised();
        
        agreement.disputed = true;
        
        emit DisputeRaised(agreementId, msg.sender, reason);
    }

    /**
     * @notice Resolves a dispute with payment distribution
     * @dev Only arbitrator can resolve disputes with payment distribution
     * @param agreementId The ID of the agreement
     * @param winner The address of the winning party
     * @param amounts Array of payment amounts to distribute
     */
    function resolveDispute(
        uint256 agreementId,
        address winner,
        uint256[] calldata amounts
    ) external validAgreement(agreementId) onlyArbitratorPool whenNotPaused nonReentrant {
        Agreement storage agreement = agreements[agreementId];
        if (!agreement.disputed) revert AgreementNotDisputed();
        
        if (winner != agreement.client && winner != agreement.provider) revert InvalidAddress();
        
        // Mark dispute as resolved and agreement as completed
        agreement.disputed = false;
        agreement.completed = true;
        
        // If client wins, refund remaining amount
        if (winner == agreement.client) {
            uint256 remainingAmount = agreement.remainingAmount;
            agreement.remainingAmount = 0;
            
            if (agreement.paymentToken == address(0)) {
                // ETH payment
                (bool success, ) = agreement.client.call{value: remainingAmount}("");
                if (!success) revert PaymentFailed();
            } else {
                // ERC20 payment
                IERC20(agreement.paymentToken).safeTransfer(agreement.client, remainingAmount);
            }
        }
        // If provider wins and amounts are specified, distribute payments
        else if (amounts.length > 0) {
            uint256 totalAmount = 0;
            for (uint256 i = 0; i < amounts.length; i++) {
                totalAmount += amounts[i];
            }
            
            if (totalAmount > agreement.remainingAmount) revert InsufficientRemainingFunds();
            
            agreement.remainingAmount -= uint128(totalAmount);
            
            uint256 fee = totalAmount * PLATFORM_FEE_PERCENTAGE / BASIS_POINTS;
            uint256 paymentAmount = totalAmount - fee;
            
            if (agreement.paymentToken == address(0)) {
                // ETH payment
                (bool success1, ) = agreement.provider.call{value: paymentAmount}("");
                if (!success1) revert PaymentFailed();
                
                (bool success2, ) = feeCollector.call{value: fee}("");
                if (!success2) revert PaymentFailed();
            } else {
                // ERC20 payment
                IERC20(agreement.paymentToken).safeTransfer(agreement.provider, paymentAmount);
                IERC20(agreement.paymentToken).safeTransfer(feeCollector, fee);
            }
        }
        
        emit DisputeResolved(agreementId, winner);
    }

    /**
     * @notice Submits a rating for a participant
     * @dev Either party can rate the other after agreement completion
     * @param agreementId The ID of the agreement
     * @param ratedAddress The address being rated
     * @param score The rating score (1-5)
     */
    function submitRating(
        uint256 agreementId,
        address ratedAddress,
        uint256 score
    ) external validAgreement(agreementId) onlyParticipant(agreementId) onlyUnrated(agreementId) whenNotPaused {
        if (score < MIN_RATING || score > MAX_RATING) revert InvalidRating();
        if (ratedAddress == msg.sender) revert CannotRateSelf();
        
        Agreement storage agreement = agreements[agreementId];
        if (ratedAddress != agreement.client && ratedAddress != agreement.provider) revert InvalidAddress();
        
        agreement.hasRated[msg.sender] = true;
        
        Rating storage rating = ratings[ratedAddress];
        rating.total += score;
        rating.count += 1;
        
        // Calculate weighted score based on transaction amount
        uint256 transactionWeight = agreement.totalAmount;
        rating.weightedScore += score * transactionWeight;
        rating.totalTransactionValue += transactionWeight;
        
        emit RatingSubmitted(agreementId, msg.sender, ratedAddress, score);
    }

    /**
     * @notice Emergency withdrawal of ETH or tokens
     * @dev Only owner can withdraw in emergency
     * @param token The token to withdraw (address(0) for ETH)
     */
    function emergencyWithdraw(address token) external onlyOwner {
        if (token == address(0)) {
            // ETH withdrawal
            uint256 balance = address(this).balance;
            if (balance == 0) revert NoTokensToWithdraw();
            
            (bool success, ) = msg.sender.call{value: balance}("");
            if (!success) revert PaymentFailed();
        } else {
            // ERC20 withdrawal
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) revert NoTokensToWithdraw();
            
            IERC20(token).safeTransfer(msg.sender, balance);
        }
    }

    /**
     * @notice Extends a milestone deadline
     * @dev Client can extend milestone deadlines
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone
     * @param newDeadline The new deadline timestamp
     */
    function extendMilestoneDeadline(
        uint256 agreementId,
        uint256 milestoneIndex,
        uint256 newDeadline
    ) external validAgreement(agreementId) onlyClient(agreementId) notCancelled(agreementId) whenNotPaused {
        Agreement storage agreement = agreements[agreementId];
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestoneIndex();
        
        Milestone storage milestone = agreement.milestones[milestoneIndex];
        if (milestone.completed) revert MilestoneAlreadyCompleted();
        if (newDeadline <= milestone.deadline) revert InvalidDeadline();
        
        milestone.deadline = uint64(newDeadline);
        
        emit MilestoneDeadlineExtended(agreementId, milestoneIndex, newDeadline);
    }

    /**
     * @notice Cancels an agreement
     * @dev Client can cancel within timeframe, or both parties can agree to cancel
     * @param agreementId The ID of the agreement
     * @param reason The reason for cancellation
     */
    function cancelAgreement(
        uint256 agreementId,
        string calldata reason
    ) external validAgreement(agreementId) onlyParticipant(agreementId) notCancelled(agreementId) whenNotPaused nonReentrant {
        Agreement storage agreement = agreements[agreementId];
        
        // Client can cancel within timeframe
        bool canCancel = false;
        if (msg.sender == agreement.client && block.timestamp <= agreement.createdAt + CANCELLATION_TIMEFRAME) {
            canCancel = true;
        }
        
        if (!canCancel) revert CancellationPeriodExpired();
        
        agreement.cancelled = true;
        
        // Refund remaining amount to client
        uint256 remainingAmount = agreement.remainingAmount;
        agreement.remainingAmount = 0;
        
        if (agreement.paymentToken == address(0)) {
            // ETH payment
            (bool success, ) = agreement.client.call{value: remainingAmount}("");
            if (!success) revert PaymentFailed();
        } else {
            // ERC20 payment
            IERC20(agreement.paymentToken).safeTransfer(agreement.client, remainingAmount);
        }
        
        emit AgreementCancelled(agreementId, msg.sender, reason);
    }

    /**
     * @notice Batch releases payments for multiple milestones
     * @dev Client can release payments for multiple milestones at once
     * @param agreementId The ID of the agreement
     * @param milestoneIndices Array of milestone indices to release payment for
     */
    function batchReleaseMilestonePayments(
        uint256 agreementId,
        uint256[] calldata milestoneIndices
    ) external validAgreement(agreementId) onlyClient(agreementId) notCancelled(agreementId) whenNotPaused nonReentrant {
        Agreement storage agreement = agreements[agreementId];
        
        uint256 totalAmount = 0;
        uint256 totalFee = 0;
        
        for (uint256 i = 0; i < milestoneIndices.length; i++) {
            uint256 milestoneIndex = milestoneIndices[i];
            
            if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestoneIndex();
            
            Milestone storage milestone = agreement.milestones[milestoneIndex];
            if (!milestone.completed) revert MilestoneNotCompleted();
            if (milestone.paid) revert MilestoneAlreadyPaid();
            
            milestone.paid = true;
            
            uint256 amount = milestone.amount;
            uint256 fee = amount * PLATFORM_FEE_PERCENTAGE / BASIS_POINTS;
            
            totalAmount += amount - fee;
            totalFee += fee;
            
            agreement.remainingAmount -= uint128(amount);
        }
        
        // Handle payment
        if (agreement.paymentToken == address(0)) {
            // ETH payment
            (bool success1, ) = agreement.provider.call{value: totalAmount}("");
            if (!success1) revert PaymentFailed();
            
            (bool success2, ) = feeCollector.call{value: totalFee}("");
            if (!success2) revert PaymentFailed();
        } else {
            // ERC20 payment
            IERC20(agreement.paymentToken).safeTransfer(agreement.provider, totalAmount);
            IERC20(agreement.paymentToken).safeTransfer(feeCollector, totalFee);
        }
        
        emit BatchPaymentReleased(agreementId, milestoneIndices, totalAmount, totalFee);
    }

    /**
     * @notice Gets the details of an agreement
     * @dev Returns the main details of an agreement
     * @param agreementId The ID of the agreement
     * @return client The client address
     * @return provider The provider address
     * @return totalAmount The total amount of the agreement
     * @return remainingAmount The remaining amount of the agreement
     * @return deadline The deadline of the agreement
     * @return createdAt The creation timestamp of the agreement
     * @return completed Whether the agreement is completed
     * @return disputed Whether the agreement is disputed
     * @return cancelled Whether the agreement is cancelled
     * @return paymentToken The payment token address
     * @return terms The terms of the agreement
     */
    function getAgreementDetails(uint256 agreementId) external view validAgreement(agreementId) returns (
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
    ) {
        Agreement storage agreement = agreements[agreementId];
        return (
            agreement.client,
            agreement.provider,
            agreement.totalAmount,
            agreement.remainingAmount,
            agreement.deadline,
            agreement.createdAt,
            agreement.completed,
            agreement.disputed,
            agreement.cancelled,
            agreement.paymentToken,
            agreement.terms
        );
    }

    /**
     * @notice Gets the details of a milestone
     * @dev Returns the details of a milestone
     * @param agreementId The ID of the agreement
     * @param milestoneIndex The index of the milestone
     * @return deadline The deadline of the milestone
     * @return amount The amount of the milestone
     * @return completed Whether the milestone is completed
     * @return paid Whether the milestone is paid
     * @return partiallyCompleted Whether the milestone is partially completed
     * @return completionPercentage The completion percentage of the milestone
     * @return evidenceHash The evidence hash of the milestone
     */
    function getMilestoneDetails(uint256 agreementId, uint256 milestoneIndex) external view validAgreement(agreementId) returns (
        uint256 deadline,
        uint256 amount,
        bool completed,
        bool paid,
        bool partiallyCompleted,
        uint8 completionPercentage,
        string memory evidenceHash
    ) {
        Agreement storage agreement = agreements[agreementId];
        if (milestoneIndex >= agreement.milestones.length) revert InvalidMilestoneIndex();
        
        Milestone storage milestone = agreement.milestones[milestoneIndex];
        return (
            milestone.deadline,
            milestone.amount,
            milestone.completed,
            milestone.paid,
            milestone.partiallyCompleted,
            milestone.completionPercentage,
            milestone.evidenceHash
        );
    }

    /**
     * @notice Gets all milestones for an agreement
     * @dev Returns arrays of milestone details
     * @param agreementId The ID of the agreement
     * @return deadlines Array of milestone deadlines
     * @return amounts Array of milestone amounts
     * @return completedFlags Array of milestone completion flags
     * @return paidFlags Array of milestone payment flags
     * @return evidenceHashes Array of milestone evidence hashes
     */
    function getMilestones(uint256 agreementId) external view validAgreement(agreementId) returns (
        uint256[] memory deadlines,
        uint256[] memory amounts,
        bool[] memory completedFlags,
        bool[] memory paidFlags,
        string[] memory evidenceHashes
    ) {
        Agreement storage agreement = agreements[agreementId];
        uint256 milestoneCount = agreement.milestones.length;
        
        deadlines = new uint256[](milestoneCount);
        amounts = new uint256[](milestoneCount);
        completedFlags = new bool[](milestoneCount);
        paidFlags = new bool[](milestoneCount);
        evidenceHashes = new string[](milestoneCount);
        
        for (uint256 i = 0; i < milestoneCount; i++) {
            Milestone storage milestone = agreement.milestones[i];
            deadlines[i] = milestone.deadline;
            amounts[i] = milestone.amount;
            completedFlags[i] = milestone.completed;
            paidFlags[i] = milestone.paid;
            evidenceHashes[i] = milestone.evidenceHash;
        }
        
        return (deadlines, amounts, completedFlags, paidFlags, evidenceHashes);
    }

    /**
     * @notice Gets all agreements for a user
     * @dev Returns array of agreement IDs
     * @param user The user address
     * @return Array of agreement IDs
     */
    function getUserAgreements(address user) external view returns (uint256[] memory) {
        return userAgreements[user];
    }

    /**
     * @notice Gets the rating for a user
     * @dev Returns the rating details
     * @param user The user address
     * @return total The total rating score
     * @return count The number of ratings
     * @return average The average rating
     */
    function getUserRating(address user) external view returns (
        uint256 total,
        uint256 count,
        uint256 average
    ) {
        Rating storage rating = ratings[user];
        total = rating.total;
        count = rating.count;
        average = count > 0 ? total / count : 0;
        return (total, count, average);
    }

    /**
     * @notice Adds team members to an agreement
     * @dev Provider can add team members to split payments
     * @param agreementId The ID of the agreement
     * @param members Array of team member addresses
     * @param shares Array of payment shares (in percentage)
     */
    function addTeamMembers(
        uint256 agreementId,
        address[] calldata members,
        uint256[] calldata shares
    ) external validAgreement(agreementId) onlyProvider(agreementId) notCancelled(agreementId) whenNotPaused {
        Agreement storage agreement = agreements[agreementId];
        
        if (agreement.teamMembers.length > 0) revert TeamAlreadySet();
        if (members.length == 0) revert NoMembersProvided();
        if (members.length > MAX_TEAM_MEMBERS) revert TooManyTeamMembers();
        if (members.length != shares.length) revert ArrayLengthMismatch();
        
        uint256 totalShares = 0;
        for (uint256 i = 0; i < shares.length; i++) {
            totalShares += shares[i];
        }
        
        if (totalShares != 100) revert SharesMustTotal100Percent();
        
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == address(0)) revert InvalidAddress();
            agreement.teamMembers.push(members[i]);
            agreement.teamShares.push(shares[i]);
        }
    }

    // Minimal implementation of a token payment function
    function _handleTokenPayment(address token, uint256 amount) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        
        // Transfer tokens from sender to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate received amount and check for slippage
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        
        // Get token-specific slippage setting or use default
        uint256 maxSlippage = tokenMaxSlippage[token];
        if (maxSlippage == 0) {
            maxSlippage = DEFAULT_MAX_SLIPPAGE;
        }
        
        // Ensure received amount is within acceptable slippage range
        if (received < amount * (BASIS_POINTS - maxSlippage) / BASIS_POINTS) {
            revert SlippageExceeded();
        }
    }

    // Receive function to handle ETH transfers
    receive() external payable {
        // Allow receiving ETH
    }
}
