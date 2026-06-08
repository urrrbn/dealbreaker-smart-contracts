// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";

import {EscrowTestBase} from "../utils/EscrowTestBase.sol";
import {Escrow} from "../../src/Escrow.sol";
import {IEscrow} from "../../src/interfaces/IEscrow.sol";
import {EscrowHandler} from "./handlers/EscrowHandler.sol";

contract EscrowInvariantTest is EscrowTestBase {
    EscrowHandler internal handler;
    Escrow internal escrow;

    // Immutable snapshot taken right after activation.
    address internal s_factory;
    address internal s_founder;
    address internal s_investor;
    address internal s_token;
    address internal s_arbitrator;
    uint16 internal s_feeBps;
    uint32 internal s_gracePeriod;
    uint256 internal s_milestoneCount;

    function setUp() public override {
        super.setUp();

        escrow = _deployDefault();
        _activate(escrow);

        s_factory = escrow.factory();
        s_founder = escrow.founder();
        s_investor = escrow.investor();
        s_token = escrow.token();
        s_arbitrator = escrow.arbitrator();
        s_feeBps = escrow.feeBps();
        s_gracePeriod = escrow.gracePeriod();
        s_milestoneCount = escrow.getEscrowSummary().milestoneCount;

        handler = new EscrowHandler(escrow, token, founderPk, investorPk, arbitratorPk);

        targetContract(address(handler));
    }

    // -----------------------------------------------------------------
    // Solvency / balances
    // -----------------------------------------------------------------

    /// @dev token.balanceOf(escrow) == Σ amount over milestones in {Funded, Refundable}.
    function invariant_holdingMatchesBackedMilestones() public view {
        uint256 expected;
        uint256 n = escrow.getEscrowSummary().milestoneCount;
        for (uint256 i = 0; i < n; i++) {
            IEscrow.MilestoneState st = escrow.getMilestone(i).state;
            if (st == IEscrow.MilestoneState.Funded || st == IEscrow.MilestoneState.Refundable) {
                expected += escrow.getMilestone(i).amount;
            }
        }
        assertEq(token.balanceOf(address(escrow)), expected);
    }

    /// @dev Terminal escrow holds no funds.
    function invariant_noStuckFundsWhenTerminal() public view {
        IEscrow.EscrowState s = escrow.escrowState();
        if (s == IEscrow.EscrowState.Finalized || s == IEscrow.EscrowState.Cancelled) {
            assertEq(token.balanceOf(address(escrow)), 0);
        }
    }

    /// @dev A Refundable milestone is always backed by its full deposit.
    function invariant_refundableIsBacked() public view {
        uint256 idx = escrow.currentMilestoneIndex();
        IEscrow.Milestone memory m = escrow.getMilestone(idx);
        if (m.state == IEscrow.MilestoneState.Refundable) {
            assertGe(token.balanceOf(address(escrow)), m.amount);
        }
    }

    // -----------------------------------------------------------------
    // State machine
    // -----------------------------------------------------------------

    function invariant_currentIndexInRange() public view {
        assertLt(escrow.currentMilestoneIndex(), escrow.getEscrowSummary().milestoneCount);
    }

    /// @dev Per-milestone state partitioning relative to the current index.
    function invariant_milestonePartitioning() public view {
        uint256 current = escrow.currentMilestoneIndex();
        uint256 n = escrow.getEscrowSummary().milestoneCount;
        bool active = escrow.escrowState() == IEscrow.EscrowState.Active;

        for (uint256 i = 0; i < n; i++) {
            IEscrow.MilestoneState st = escrow.getMilestone(i).state;
            // Verified is transient and must never persist between txs.
            assertTrue(st != IEscrow.MilestoneState.Verified);

            if (i > current) {
                assertTrue(st == IEscrow.MilestoneState.Pending);
            } else if (i < current) {
                assertTrue(st == IEscrow.MilestoneState.Released || st == IEscrow.MilestoneState.Refunded);
            } else if (active) {
                // current milestone while Active
                assertTrue(
                    st == IEscrow.MilestoneState.Active || st == IEscrow.MilestoneState.Funded
                        || st == IEscrow.MilestoneState.Refundable
                );
            }
        }
    }

    /// @dev Finalized ⟺ last milestone Released; Cancelled ⟹ last milestone Refunded.
    function invariant_terminalConsistency() public view {
        uint256 n = escrow.getEscrowSummary().milestoneCount;
        IEscrow.MilestoneState last = escrow.getMilestone(n - 1).state;
        IEscrow.EscrowState s = escrow.escrowState();

        if (s == IEscrow.EscrowState.Finalized) {
            assertTrue(last == IEscrow.MilestoneState.Released);
        }
        if (s == IEscrow.EscrowState.Cancelled) {
            assertTrue(last == IEscrow.MilestoneState.Refunded);
        }
    }

    /// @dev Monotonic index / escrow-state / nonces, asserted via handler ghosts.
    function invariant_monotonicProgress() public view {
        assertFalse(handler.ghost_indexBroke());
        assertFalse(handler.ghost_stateBroke());
        assertFalse(handler.ghost_nonceBroke());
    }

    // -----------------------------------------------------------------
    // Disputes
    // -----------------------------------------------------------------

    /// @dev A dispute can only ever exist on the current milestone.
    function invariant_disputeOnlyOnCurrentMilestone() public view {
        uint256 current = escrow.currentMilestoneIndex();
        uint256 n = escrow.getEscrowSummary().milestoneCount;
        for (uint256 i = 0; i < n; i++) {
            if (i != current) {
                assertEq(escrow.getDisputeInfo(i).openedAt, 0);
            }
        }
    }

    // -----------------------------------------------------------------
    // Immutability
    // -----------------------------------------------------------------

    function invariant_immutablesFrozen() public view {
        assertEq(escrow.factory(), s_factory);
        assertEq(escrow.founder(), s_founder);
        assertEq(escrow.investor(), s_investor);
        assertEq(escrow.token(), s_token);
        assertEq(escrow.arbitrator(), s_arbitrator);
        assertEq(escrow.feeBps(), s_feeBps);
        assertEq(escrow.gracePeriod(), s_gracePeriod);
        assertEq(escrow.getEscrowSummary().milestoneCount, s_milestoneCount);
        assertLe(escrow.feeBps(), 1000);
    }

    // -----------------------------------------------------------------
    // Coverage guard
    // -----------------------------------------------------------------

    function afterInvariant() public view {
        console2.log("--- successful actions ---");
        console2.log("deposits          ", handler.deposits());
        console2.log("verifications     ", handler.verifications());
        console2.log("refunds           ", handler.refunds());
        console2.log("renegotiations    ", handler.renegotiations());
        console2.log("disputesOpened    ", handler.disputesOpened());
        console2.log("disputesResolved  ", handler.disputesResolved());
    }
}
