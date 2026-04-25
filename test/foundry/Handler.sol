// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {ServiceAgreement} from "../../contracts/ServiceAgreement.sol";

/// @notice Handler invoked by Foundry's invariant runner. Each external function
/// is a fuzzable action; arguments are bounded into useful ranges so the fuzzer
/// hits valid call paths often enough to explore the state space.
///
/// The handler maintains "ghost" state used by invariants:
///   - actors[]:       addresses that may hold pendingWithdrawals balances
///   - agreementIds[]: agreements created during the run
///   - terminalAtSnap: a snapshot of (cancelled, completed) flags after each
///                     state-mutating call; used to verify terminal states are sticky.
contract Handler is CommonBase, StdCheats, StdUtils {
    ServiceAgreement public immutable svc;
    address public immutable owner;
    address public immutable arbitrator;
    address public immutable feeCollector;

    address[] public actors;
    mapping(address => bool) public isActor;

    uint256[] public agreementIds;

    struct Terminal {
        bool cancelled;
        bool completed;
    }
    mapping(uint256 => Terminal) public terminalSeen;

    constructor(ServiceAgreement svc_, address owner_, address arbitrator_, address feeCollector_) {
        svc = svc_;
        owner = owner_;
        arbitrator = arbitrator_;
        feeCollector = feeCollector_;
        _registerActor(arbitrator_);
        _registerActor(feeCollector_);
    }

    receive() external payable {}

    function _registerActor(address a) internal {
        if (a == address(0) || a == address(svc) || isActor[a]) return;
        isActor[a] = true;
        actors.push(a);
    }

    function _pickActor(uint256 seed) internal returns (address actor) {
        // Choose from a small pool so fuzzing hits the same actors repeatedly.
        actor = address(uint160(uint256(keccak256(abi.encode("actor", seed % 8)))));
        if (actor == address(0)) actor = address(uint160(uint256(keccak256(abi.encode("actor-fallback")))));
        _registerActor(actor);
        // Fund the actor so they can pay msg.value when needed.
        if (actor.balance < 100 ether) {
            vm.deal(actor, 100 ether);
        }
    }

    // ---- Operations ------------------------------------------------------

    function createAgreement(
        uint256 clientSeed,
        uint256 providerSeed,
        uint256 milestoneCountSeed,
        uint256 amountSeed,
        uint256 daysSeed
    ) external {
        address client = _pickActor(clientSeed);
        address provider = _pickActor(providerSeed | 1);
        if (provider == client) return;

        uint256 n = bound(milestoneCountSeed, 1, 5);
        uint256[] memory dueDates = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 total;
        uint256 base = block.timestamp + bound(daysSeed, 1, 30) * 1 days;
        for (uint256 i = 0; i < n; i++) {
            dueDates[i] = base + i * 1 days;
            uint256 a = bound(uint256(keccak256(abi.encode(amountSeed, i))), 0.01 ether, 1 ether);
            amounts[i] = a;
            total += a;
        }
        if (total > client.balance) return;

        vm.prank(client);
        try svc.createAgreement{value: total}(provider, "fuzz terms", dueDates, amounts, address(0)) returns (uint256 id) {
            agreementIds.push(id);
        } catch {}
    }

    function submitEvidence(uint256 agreementSeed, uint256 idxSeed, uint256 evidenceSeed) external {
        if (agreementIds.length == 0) return;
        uint256 id = agreementIds[agreementSeed % agreementIds.length];
        (, address provider,,,,,,,,,) = svc.getAgreementDetails(id);
        uint256 mLen = svc.getMilestoneCount(id);
        if (mLen == 0) return;
        uint256 idx = idxSeed % mLen;
        string memory hash = string(abi.encodePacked("ipfs://", vm.toString(evidenceSeed)));
        vm.prank(provider);
        try svc.submitMilestoneEvidence(id, idx, hash) {} catch {}
    }

    function approveMilestone(uint256 agreementSeed, uint256 idxSeed, bool useCommitment) external {
        if (agreementIds.length == 0) return;
        uint256 id = agreementIds[agreementSeed % agreementIds.length];
        (address client,,,,,,,,,,) = svc.getAgreementDetails(id);
        uint256 mLen = svc.getMilestoneCount(id);
        if (mLen == 0) return;
        uint256 idx = idxSeed % mLen;
        (,,,, string memory evidence) = svc.getMilestone(id, idx);
        bytes32 commitment = useCommitment && bytes(evidence).length > 0
            ? keccak256(bytes(evidence))
            : bytes32(0);
        vm.prank(client);
        try svc.approveMilestone(id, idx, commitment) {} catch {}
        _snapshotTerminal(id);
    }

    function raiseDispute(uint256 agreementSeed, uint256 sideSeed) external {
        if (agreementIds.length == 0) return;
        uint256 id = agreementIds[agreementSeed % agreementIds.length];
        (address client, address provider,,,,,,,,,) = svc.getAgreementDetails(id);
        address party = (sideSeed % 2 == 0) ? client : provider;
        vm.prank(party);
        try svc.raiseDispute(id, "fuzz") {} catch {}
        _snapshotTerminal(id);
    }

    function resolveDispute(uint256 agreementSeed, uint256 amountSeed) external {
        if (agreementIds.length == 0) return;
        uint256 id = agreementIds[agreementSeed % agreementIds.length];
        (,,, uint256 remaining,,,,,,,) = svc.getAgreementDetails(id);
        if (remaining == 0) return;
        uint256 amountToProvider = bound(amountSeed, 0, remaining);
        vm.prank(arbitrator);
        try svc.resolveDispute(id, amountToProvider) {} catch {}
        _snapshotTerminal(id);
    }

    function cancelAgreement(uint256 agreementSeed) external {
        if (agreementIds.length == 0) return;
        uint256 id = agreementIds[agreementSeed % agreementIds.length];
        (address client,,,,,,,,,,) = svc.getAgreementDetails(id);
        vm.prank(client);
        try svc.cancelAgreement(id, "fuzz") {} catch {}
        _snapshotTerminal(id);
    }

    function withdraw(uint256 actorSeed) external {
        address actor = _pickActor(actorSeed);
        vm.prank(actor);
        try svc.withdraw(address(0)) {} catch {}
    }

    function withdrawSurplus(uint256 actorSeed) external {
        address recipient = _pickActor(actorSeed);
        vm.prank(owner);
        try svc.withdrawSurplus(address(0), recipient) {} catch {}
    }

    function timeJump(uint256 daysSeed) external {
        uint256 d = bound(daysSeed, 1, 30);
        skip(d * 1 days);
    }

    function _snapshotTerminal(uint256 id) internal {
        (,,,,,,bool completed,,bool cancelled,,) = svc.getAgreementDetails(id);
        Terminal memory t = terminalSeen[id];
        if (cancelled) t.cancelled = true;
        if (completed) t.completed = true;
        terminalSeen[id] = t;
    }

    // ---- Ghost reads used by invariants ----------------------------------

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function agreementIdsLength() external view returns (uint256) {
        return agreementIds.length;
    }

    function sumPendingETH() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += svc.pendingWithdrawals(address(0), actors[i]);
        }
    }

    function sumOpenRemainingETH() external view returns (uint256 sum) {
        for (uint256 i = 0; i < agreementIds.length; i++) {
            uint256 id = agreementIds[i];
            (,,, uint256 remaining,,, bool completed,, bool cancelled,,) = svc.getAgreementDetails(id);
            if (!completed && !cancelled) sum += remaining;
        }
    }

    /// @dev Used by the terminal-stickiness invariant. Checks that no agreement
    /// previously seen as cancelled or completed is now in a different state.
    function terminalStatesMatch() external view returns (bool) {
        for (uint256 i = 0; i < agreementIds.length; i++) {
            uint256 id = agreementIds[i];
            Terminal memory t = terminalSeen[id];
            if (!t.cancelled && !t.completed) continue;
            (,,,,,,bool completed,, bool cancelled,,) = svc.getAgreementDetails(id);
            if (t.cancelled && !cancelled) return false;
            if (t.completed && !completed) return false;
        }
        return true;
    }
}
