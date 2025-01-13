// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ServiceAgreement is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    struct Milestone {
        uint256 deadline;
        uint256 amount;
        bool completed;
        bool paid;
        string evidenceHash;  // IPFS hash of completion evidence
    }

    struct Agreement {
        address client;
        address provider;
        uint256 totalAmount;
        uint256 remainingAmount;
        uint256 deadline;
        bool completed;
        bool disputed;
        bool cancelled;
        string terms;
        uint256 createdAt;
        address paymentToken;
        Milestone[] milestones;
        mapping(address => bool) hasRated;
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

    // State variables
    mapping(uint256 => Agreement) public agreements;
    mapping(address => Rating) public ratings;
    mapping(address => uint256[]) public userAgreements;
    mapping(uint256 => AgreementTemplate) public templates;
    mapping(address => bool) public whitelistedTokens;
    uint256 public agreementCount;
    uint256 public templateCount;
    address public arbitrator;
    address public feeCollector;

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

    // Modifiers
    modifier onlyClient(uint256 agreementId) {
        require(msg.sender == agreements[agreementId].client, "Only client can perform this action");
        _;
    }

    modifier onlyProvider(uint256 agreementId) {
        require(msg.sender == agreements[agreementId].provider, "Only provider can perform this action");
        _;
    }

    modifier onlyParticipant(uint256 agreementId) {
        require(
            msg.sender == agreements[agreementId].client || 
            msg.sender == agreements[agreementId].provider,
            "Only agreement participants can perform this action"
        );
        _;
    }

    modifier onlyArbitrator() {
        require(msg.sender == arbitrator, "Only arbitrator can perform this action");
        _;
    }

    modifier validAgreement(uint256 agreementId) {
        require(agreementId < agreementCount, "Agreement does not exist");
        _;
    }

    modifier onlyUnrated(uint256 agreementId) {
        require(!agreements[agreementId].hasRated[msg.sender], "Already rated");
        _;
    }

    modifier notCancelled(uint256 agreementId) {
        require(!agreements[agreementId].cancelled, "Agreement is cancelled");
        _;
    }

    constructor(address _arbitrator, address _feeCollector) Ownable(msg.sender) {
        require(_arbitrator != address(0), "Invalid arbitrator address");
        require(_feeCollector != address(0), "Invalid fee collector address");
        arbitrator = _arbitrator;
        feeCollector = _feeCollector;
    }

    // Template Management Functions
    function createTemplate(
        string calldata name,
        string calldata terms,
        uint256 recommendedDuration,
        uint256 recommendedMilestones
    ) external onlyOwner returns (uint256) {
        require(recommendedMilestones <= MAX_MILESTONES, "Too many milestones");
        require(recommendedDuration <= MAX_DEADLINE, "Duration too long");

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
        require(templateId < templateCount, "Template does not exist");
        require(recommendedMilestones <= MAX_MILESTONES, "Too many milestones");
        require(recommendedDuration <= MAX_DEADLINE, "Duration too long");

        AgreementTemplate storage template = templates[templateId];
        template.name = name;
        template.terms = terms;
        template.recommendedDuration = recommendedDuration;
        template.recommendedMilestones = recommendedMilestones;
        template.active = active;

        emit TemplateUpdated(templateId, name, active);
    }

    // Agreement Creation and Management Functions
    function createAgreementFromTemplate(
        uint256 templateId,
        address provider,
        uint256[] calldata milestoneDueDates,
        uint256[] calldata milestoneAmounts,
        address paymentToken
    ) external payable whenNotPaused returns (uint256) {
        AgreementTemplate storage template = templates[templateId];
        require(template.active, "Template not active");
        
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

    function _createAgreement(
        address provider,
        string memory terms,
        uint256 deadline,
        uint256[] memory milestoneDueDates,
        uint256[] memory milestoneAmounts,
        address paymentToken,
        uint256 totalAmount
    ) internal returns (uint256) {
        require(provider != address(0) && provider != msg.sender, "Invalid provider");
        require(totalAmount > 0, "Payment required");
        require(milestoneDueDates.length == milestoneAmounts.length, "Arrays length mismatch");
        require(milestoneDueDates.length <= MAX_MILESTONES, "Too many milestones");

        if (paymentToken != address(0)) {
            require(whitelistedTokens[paymentToken], "Token not whitelisted");
            require(msg.value == 0, "ETH not accepted for token payments");
            IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), totalAmount);
        } else {
            require(msg.value == totalAmount, "Incorrect payment amount");
        }

        uint256 agreementId = agreementCount++;
        Agreement storage agreement = agreements[agreementId];
        
        agreement.client = msg.sender;
        agreement.provider = provider;
        agreement.totalAmount = totalAmount;
        agreement.remainingAmount = totalAmount;
        agreement.deadline = deadline;
        agreement.terms = terms;
        agreement.paymentToken = paymentToken;
        agreement.createdAt = block.timestamp;

        for(uint256 i = 0; i < milestoneDueDates.length; i++) {
            agreement.milestones.push(Milestone({
                deadline: milestoneDueDates[i],
                amount: milestoneAmounts[i],
                completed: false,
                paid: false,
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
        require(!agreement.disputed, "Agreement is disputed");
        require(milestoneIndex < agreement.milestones.length, "Invalid milestone");
        require(bytes(evidenceHash).length > 0, "Empty evidence hash");

        Milestone storage milestone = agreement.milestones[milestoneIndex];
        require(!milestone.completed, "Milestone already completed");
        require(block.timestamp <= milestone.deadline, "Milestone deadline passed");

        milestone.evidenceHash = evidenceHash;
        emit MilestoneEvidenceSubmitted(agreementId, milestoneIndex, evidenceHash);
    }

    function completeMilestone(uint256 agreementId, uint256 milestoneIndex) 
        external 
        onlyClient(agreementId)
        validAgreement(agreementId)
        notCancelled(agreementId)
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        require(!agreement.disputed, "Agreement is disputed");
        require(milestoneIndex < agreement.milestones.length, "Invalid milestone");

        Milestone storage milestone = agreement.milestones[milestoneIndex];
        require(!milestone.completed, "Milestone already completed");
        require(bytes(milestone.evidenceHash).length > 0, "No evidence submitted");

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

    function releaseMilestonePayment(uint256 agreementId, uint256 milestoneIndex) 
        external 
        onlyClient(agreementId) 
        validAgreement(agreementId)
        notCancelled(agreementId)
        nonReentrant 
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        require(!agreement.disputed, "Agreement is disputed");
        require(milestoneIndex < agreement.milestones.length, "Invalid milestone");

        Milestone storage milestone = agreement.milestones[milestoneIndex];
        require(milestone.completed, "Milestone not completed");
        require(!milestone.paid, "Payment already released");

        uint256 paymentAmount = milestone.amount;
        uint256 fee = (paymentAmount * PLATFORM_FEE_PERCENTAGE) / BASIS_POINTS;
        uint256 providerPayment = paymentAmount - fee;

        agreement.remainingAmount -= paymentAmount;
        milestone.paid = true;

        if (agreement.paymentToken == address(0)) {
            (bool successProvider, ) = payable(agreement.provider).call{value: providerPayment}("");
            require(successProvider, "Provider payment failed");
            
            (bool successFee, ) = payable(feeCollector).call{value: fee}("");
            require(successFee, "Fee transfer failed");
        } else {
            IERC20(agreement.paymentToken).safeTransfer(agreement.provider, providerPayment);
            IERC20(agreement.paymentToken).safeTransfer(feeCollector, fee);
        }

        emit PaymentReleased(agreementId, milestoneIndex, providerPayment, fee);
    }

    function cancelAgreement(uint256 agreementId, string calldata reason)
        external
        onlyParticipant(agreementId)
        validAgreement(agreementId)
        notCancelled(agreementId)
        whenNotPaused
    {
        Agreement storage agreement = agreements[agreementId];
        require(!agreement.disputed, "Agreement is disputed");
        require(!agreement.completed, "Agreement is completed");
        
        // Only allow cancellation within timeframe if no milestones are completed
        bool hasCompletedMilestones = false;
        for(uint256 i = 0; i < agreement.milestones.length; i++) {
            if (agreement.milestones[i].completed) {
                hasCompletedMilestones = true;
                break;
            }
        }

        if (hasCompletedMilestones) {
            require(
                msg.sender == agreement.client && 
                block.timestamp <= agreement.createdAt + CANCELLATION_TIMEFRAME,
                "Cancellation period expired"
            );
        }

        agreement.cancelled = true;

        // Return remaining funds to client
        if (agreement.remainingAmount > 0) {
            uint256 refundAmount = agreement.remainingAmount;
            agreement.remainingAmount = 0;

            if (agreement.paymentToken == address(0)) {
                (bool success, ) = payable(agreement.client).call{value: refundAmount}("");
                require(success, "Refund failed");
            } else {
                IERC20(agreement.paymentToken).safeTransfer(agreement.client, refundAmount);
            }
        }

        emit AgreementCancelled(agreementId, msg.sender, reason);
    }

    function raiseDispute(uint256 agreementId, string calldata reason) 
        external 
        onlyParticipant(agreementId) 
        validAgreement(agreementId)
        notCancelled(agreementId)
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        require(!agreement.disputed, "Dispute already raised");
        require(!agreement.completed, "Agreement already completed");
        require(agreement.remainingAmount > 0, "No funds remaining");

        agreement.disputed = true;
        emit DisputeRaised(agreementId, msg.sender, reason);
    }

    function resolveDispute(
        uint256 agreementId, 
        address winner,
        uint256[] calldata milestonePayouts
    ) 
        external 
        onlyArbitrator 
        validAgreement(agreementId) 
        nonReentrant 
        whenNotPaused 
    {
        Agreement storage agreement = agreements[agreementId];
        require(agreement.disputed, "No dispute to resolve");
        require(
            winner == agreement.client || winner == agreement.provider, 
            "Invalid winner address"
        );
        require(
            milestonePayouts.length == agreement.milestones.length,
            "Invalid payout array length"
        );

        uint256 totalPayout = 0;
        for(uint256 i = 0; i < milestonePayouts.length; i++) {
            totalPayout += milestonePayouts[i];
        }
        require(totalPayout <= agreement.remainingAmount, "Insufficient remaining funds");

        agreement.disputed = false;
        agreement.completed = true;
        agreement.remainingAmount = 0;

        // Handle payouts according to arbitrator's decision
        for(uint256 i = 0; i < milestonePayouts.length; i++) {
            if (milestonePayouts[i] > 0) {
                if (agreement.paymentToken == address(0)) {
                    (bool success, ) = payable(agreement.provider).call{value: milestonePayouts[i]}("");
                    require(success, "Provider payment failed");
                } else {
                    IERC20(agreement.paymentToken).safeTransfer(agreement.provider, milestonePayouts[i]);
                }
            }
        }

        // Return remaining funds to client
        uint256 clientRefund = agreement.remainingAmount - totalPayout;
        if (clientRefund > 0) {
            if (agreement.paymentToken == address(0)) {
                (bool success, ) = payable(agreement.client).call{value: clientRefund}("");
                require(success, "Client refund failed");
            } else {
                IERC20(agreement.paymentToken).safeTransfer(agreement.client, clientRefund);
            }
        }

        emit DisputeResolved(agreementId, winner);
    }

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
        require(score >= MIN_RATING && score <= MAX_RATING, "Invalid rating");
        Agreement storage agreement = agreements[agreementId];
        require(agreement.completed, "Agreement not completed");
        require(
            rated == agreement.client || rated == agreement.provider,
            "Invalid rated address"
        );
        require(rated != msg.sender, "Cannot rate self");

        agreement.hasRated[msg.sender] = true;
        Rating storage rating = ratings[rated];
        
        rating.total += score;
        rating.count += 1;
        rating.totalTransactionValue += agreement.totalAmount;
        rating.weightedScore = (rating.weightedScore * (rating.count - 1) + 
            score * agreement.totalAmount) / rating.totalTransactionValue;

        emit RatingSubmitted(agreementId, msg.sender, rated, score);
    }

    // Admin functions
    function setArbitrator(address _newArbitrator) external onlyOwner {
        require(_newArbitrator != address(0), "Invalid arbitrator address");
        address oldArbitrator = arbitrator;
        arbitrator = _newArbitrator;
        emit ArbitratorUpdated(oldArbitrator, _newArbitrator);
    }

    function setFeeCollector(address _newCollector) external onlyOwner {
        require(_newCollector != address(0), "Invalid fee collector address");
        address oldCollector = feeCollector;
        feeCollector = _newCollector;
        emit FeeCollectorUpdated(oldCollector, _newCollector);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function addWhitelistedToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token address");
        whitelistedTokens[token] = true;
        emit TokenWhitelisted(token, true);
    }

    function removeWhitelistedToken(address token) external onlyOwner {
        whitelistedTokens[token] = false;
        emit TokenWhitelisted(token, false);
    }

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
        require(!agreement.disputed, "Agreement is disputed");
        require(milestoneIndex < agreement.milestones.length, "Invalid milestone index");
        require(newDeadline > block.timestamp, "Invalid new deadline");
        require(newDeadline <= agreement.deadline, "Cannot exceed agreement deadline");
        
        agreement.milestones[milestoneIndex].deadline = newDeadline;
        emit MilestoneDeadlineExtended(agreementId, milestoneIndex, newDeadline);
    }

    function emergencyWithdraw(address token) external onlyOwner {
        if (token == address(0)) {
            (bool success, ) = payable(owner()).call{value: address(this).balance}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20 tokenContract = IERC20(token);
            uint256 balance = tokenContract.balanceOf(address(this));
            require(balance > 0, "No tokens to withdraw");
            tokenContract.safeTransfer(owner(), balance);
        }
    }

    // View functions
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
        require(milestoneIndex < agreement.milestones.length, "Invalid milestone index");
        
        Milestone storage milestone = agreement.milestones[milestoneIndex];
        return (
            milestone.deadline,
            milestone.amount,
            milestone.completed,
            milestone.paid,
            milestone.evidenceHash
        );
    }

    function getUserAgreements(address user) external view returns (uint256[] memory) {
        return userAgreements[user];
    }

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
}