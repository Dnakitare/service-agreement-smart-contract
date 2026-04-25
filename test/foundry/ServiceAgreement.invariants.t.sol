// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ServiceAgreement} from "../../contracts/ServiceAgreement.sol";
import {Handler} from "./Handler.sol";

/// @notice Foundry invariant tests. Each `invariant_*` function is checked after
/// every random sequence of Handler calls the fuzzer generates. Configured by
/// foundry.toml: 256 runs × 32 calls/run × ~10 handler functions.
contract ServiceAgreementInvariants is Test {
    ServiceAgreement internal svc;
    Handler internal handler;

    address internal constant OWNER = address(0xA110CE);
    address internal constant ARBITRATOR = address(0xA1A1);
    address internal constant FEE_COLLECTOR = address(0xFE0FEE);

    function setUp() public {
        ServiceAgreement impl = new ServiceAgreement();
        bytes memory initData = abi.encodeCall(ServiceAgreement.initialize, (ARBITRATOR, FEE_COLLECTOR));
        vm.prank(OWNER);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        svc = ServiceAgreement(payable(address(proxy)));

        vm.prank(OWNER);
        svc.createTemplate("Default", "Default terms", 30 days, 3);

        handler = new Handler(svc, OWNER, ARBITRATOR, FEE_COLLECTOR);

        // Restrict the fuzzer to the handler. Without this it would try to call
        // svc directly with random selectors / args, mostly reverting.
        targetContract(address(handler));

        // Whitelist the handler-exposed selectors. Skips view functions and
        // anything we don't want fuzzed (no targetContract on svc itself).
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = Handler.createAgreement.selector;
        selectors[1] = Handler.submitEvidence.selector;
        selectors[2] = Handler.approveMilestone.selector;
        selectors[3] = Handler.raiseDispute.selector;
        selectors[4] = Handler.resolveDispute.selector;
        selectors[5] = Handler.cancelAgreement.selector;
        selectors[6] = Handler.withdraw.selector;
        selectors[7] = Handler.withdrawSurplus.selector;
        selectors[8] = Handler.timeJump.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Solvency: ETH balance never falls below totalObligations.
    function invariant_solvency() public view {
        assertGe(
            address(svc).balance,
            svc.totalObligations(address(0)),
            "balance(ETH) < totalObligations(ETH)"
        );
    }

    /// @notice Conservation: pending withdrawals + remaining escrow on open
    /// agreements equals totalObligations.
    function invariant_conservation() public view {
        uint256 pending = handler.sumPendingETH();
        uint256 openRemaining = handler.sumOpenRemainingETH();
        assertEq(
            pending + openRemaining,
            svc.totalObligations(address(0)),
            "pending + openRemaining != totalObligations"
        );
    }

    /// @notice Terminal state stickiness: once `cancelled` or `completed`, an
    /// agreement does not transition back. (Verified per-id by the handler
    /// snapshot-and-recheck mechanism.)
    function invariant_terminalStatesAreSticky() public view {
        assertTrue(
            handler.terminalStatesMatch(),
            "an agreement transitioned away from a terminal state"
        );
    }

    /// @notice Surplus: balance can never exceed obligations by more than what
    /// was sent directly (and surplus, if any, is recoverable via withdrawSurplus).
    /// We don't test the bound here — just that the balance doesn't go negative
    /// relative to obligations, which is the solvency invariant above.

    function invariant_callSummary() public view {
        // Print at the end so we know the fuzzer actually exercised things.
        // forge-std prints these only with -v / --invariant-shrink-sequence-size 0
    }
}
