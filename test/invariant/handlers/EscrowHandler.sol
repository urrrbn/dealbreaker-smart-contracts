// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {Escrow} from "../../../src/Escrow.sol";
import {IEscrow} from "../../../src/interfaces/IEscrow.sol";
import {MockERC20} from "../../utils/MockERC20.sol";

contract EscrowHandler is CommonBase, StdCheats, StdUtils {
    Escrow public escrow;
    MockERC20 public token;

    uint256 internal founderPk;
    uint256 internal investorPk;
    uint256 internal arbitratorPk;
    address public founder;
    address public investor;
    address public arbitrator;

    // Ghosts
    uint256 internal ghost_lastIndex;
    uint8 internal ghost_lastState;
    uint256 internal ghost_lastFounderNonce;
    uint256 internal ghost_lastInvestorNonce;

    bool public ghost_indexBroke;
    bool public ghost_stateBroke;
    bool public ghost_nonceBroke;

    // Coverage counters
    uint256 public deposits;
    uint256 public verifications;
    uint256 public refunds;
    uint256 public renegotiations;
    uint256 public disputesOpened;
    uint256 public disputesResolved;

    constructor(Escrow escrow_, MockERC20 token_, uint256 founderPk_, uint256 investorPk_, uint256 arbitratorPk_) {
        escrow = escrow_;
        token = token_;
        founderPk = founderPk_;
        investorPk = investorPk_;
        arbitratorPk = arbitratorPk_;
        founder = vm.addr(founderPk_);
        investor = vm.addr(investorPk_);
        arbitrator = vm.addr(arbitratorPk_);

        ghost_lastIndex = escrow.currentMilestoneIndex();
        ghost_lastState = uint8(escrow.escrowState());
        ghost_lastFounderNonce = escrow.nonces(founder);
        ghost_lastInvestorNonce = escrow.nonces(investor);
    }

    modifier track() {
        _;
        uint256 idx = escrow.currentMilestoneIndex();
        if (idx < ghost_lastIndex) ghost_indexBroke = true;
        ghost_lastIndex = idx;

        uint8 st = uint8(escrow.escrowState());
        if (st < ghost_lastState) ghost_stateBroke = true;
        ghost_lastState = st;

        uint256 fn = escrow.nonces(founder);
        if (fn < ghost_lastFounderNonce) ghost_nonceBroke = true;
        ghost_lastFounderNonce = fn;

        uint256 inv = escrow.nonces(investor);
        if (inv < ghost_lastInvestorNonce) ghost_nonceBroke = true;
        ghost_lastInvestorNonce = inv;
    }

    // -----------------------------------------------------------------
    // Signature helpers (mirror Escrow's encoding)
    // -----------------------------------------------------------------

    function _sign(uint256 pk, bytes memory encoded) internal view returns (bytes memory) {
        bytes32 digest = escrow.getSignedHash(escrow.bytesToString(encoded));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _warpForward(uint256 delta) internal {
        delta = bound(delta, 0, 5 days);
        vm.warp(block.timestamp + delta);
    }

    function _current() internal view returns (IEscrow.Milestone memory) {
        return escrow.getMilestone(escrow.currentMilestoneIndex());
    }

    // -----------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------

    function warp(uint256 delta) external track {
        _warpForward(delta);
    }

    function deposit() external track {
        uint256 idx = escrow.currentMilestoneIndex();
        IEscrow.Milestone memory m = escrow.getMilestone(idx);
        if (m.state != IEscrow.MilestoneState.Active) return;
        token.mint(address(this), m.amount);
        token.approve(address(escrow), m.amount);
        try escrow.deposit(idx) {
            deposits++;
        } catch {}
    }

    function fundAndVerify() external track {
        uint256 idx = escrow.currentMilestoneIndex();
        IEscrow.Milestone memory m = escrow.getMilestone(idx);
        if (m.state != IEscrow.MilestoneState.Active) return;

        token.mint(address(this), m.amount);
        token.approve(address(escrow), m.amount);
        try escrow.deposit(idx) {
            deposits++;
        } catch {
            return;
        }

        // Verify while we are still within grace (we have not warped, so block.timestamp <= graceEndsAt).
        uint256 dl = block.timestamp + 1 days;
        bytes memory sig =
            _sign(investorPk, abi.encode(address(escrow), idx, investor, dl, block.chainid, escrow.nonces(investor)));
        try escrow.verifyMilestone(idx, keccak256("ev"), sig, dl) {
            verifications++;
        } catch {}
    }

    function verify(uint256 timeSeed) external track {
        uint256 idx = escrow.currentMilestoneIndex();
        IEscrow.Milestone memory m = escrow.getMilestone(idx);
        if (m.state != IEscrow.MilestoneState.Funded) return;
        // land at or before graceEndsAt so the call can succeed
        if (timeSeed % 2 == 0 && block.timestamp < m.deadline) {
            vm.warp(uint256(m.deadline));
        }
        uint256 dl = block.timestamp + 1 days;
        bytes memory sig =
            _sign(investorPk, abi.encode(address(escrow), idx, investor, dl, block.chainid, escrow.nonces(investor)));
        try escrow.verifyMilestone(idx, keccak256("ev"), sig, dl) {
            verifications++;
        } catch {}
    }

    function renegotiate(uint256 newAmount, uint256 deadlineDelta) external track {
        uint256 idx = escrow.currentMilestoneIndex();
        newAmount = bound(newAmount, 1, 500 ether);
        uint64 nd = uint64(block.timestamp + bound(deadlineDelta, 1 days, 30 days));
        bytes32 ndh = keccak256(abi.encode("reneg", newAmount, nd));
        uint256 dl = block.timestamp + 1 days;

        address[] memory signers = new address[](2);
        signers[0] = founder;
        signers[1] = investor;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(
            founderPk,
            abi.encode(address(escrow), idx, nd, newAmount, ndh, founder, dl, block.chainid, escrow.nonces(founder))
        );
        sigs[1] = _sign(
            investorPk,
            abi.encode(address(escrow), idx, nd, newAmount, ndh, investor, dl, block.chainid, escrow.nonces(investor))
        );
        try escrow.renegotiateMilestone(idx, nd, newAmount, ndh, signers, sigs, dl) {
            renegotiations++;
        } catch {}
    }

    function claimRefund(uint256 timeSeed) external track {
        uint256 idx = escrow.currentMilestoneIndex();
        IEscrow.Milestone memory m = escrow.getMilestone(idx);
        // push past grace sometimes so the refund is claimable
        if (timeSeed % 2 == 0 && block.timestamp <= m.graceEndsAt) {
            vm.warp(uint256(m.graceEndsAt) + 1);
        }
        vm.prank(investor);
        try escrow.claimRefund(idx) {
            refunds++;
        } catch {}
    }

    function createDispute(uint256 actorSeed) external track {
        uint256 idx = escrow.currentMilestoneIndex();
        IEscrow.Milestone memory m = escrow.getMilestone(idx);
        // move into (deadline, graceEndsAt] window when possible
        if (block.timestamp <= m.deadline && m.graceEndsAt > m.deadline) {
            vm.warp(uint256(m.deadline) + 1);
        }
        address actor = actorSeed % 2 == 0 ? founder : investor;
        vm.prank(actor);
        try escrow.createDispute(idx, keccak256("eviD")) {
            disputesOpened++;
        } catch {}
    }

    function resolveByArbitrator(bool releaseToFounder) external track {
        uint256 idx = escrow.currentMilestoneIndex();
        vm.prank(arbitrator);
        try escrow.resolveDisputeByArbitrator(idx, releaseToFounder) {
            disputesResolved++;
        } catch {}
    }

    function resolveExpired(uint256 timeSeed) external track {
        uint256 idx = escrow.currentMilestoneIndex();
        IEscrow.DisputeInfo memory d = escrow.getDisputeInfo(idx);
        if (d.openedAt != 0 && timeSeed % 2 == 0 && block.timestamp <= d.endsAt) {
            vm.warp(uint256(d.endsAt) + 1);
        }
        try escrow.resolveExpiredDispute(idx) {
            disputesResolved++;
        } catch {}
    }
}
