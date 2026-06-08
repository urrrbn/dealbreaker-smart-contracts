// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {EscrowTestBase} from "./utils/EscrowTestBase.sol";
import {Escrow} from "../src/Escrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {Errors} from "../src/lib/Errors.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract EscrowTest is EscrowTestBase {
    bytes32 internal constant EVIDENCE = keccak256("evidence");

    // Mirror the events for expectEmit checks.
    event EscrowActivated(uint64 activatedAt);
    event MilestoneDeposited(uint256 indexed milestoneIndex, address indexed investor, uint256 amount);
    event MilestoneReleased(
        uint256 indexed milestoneIndex, address indexed founder, uint256 amountToFounder, uint256 feeAmount
    );
    event MilestoneRefunded(uint256 indexed milestoneIndex, address indexed investor, uint256 amount);
    event EscrowCancelled(uint64 cancelledAt);
    event DisputeCreated(
        uint256 indexed milestoneIndex, address indexed initiator, bytes32 evidenceHash, uint64 endsAt
    );
    event MilestoneForceReleased(
        uint256 indexed milestoneIndex, address indexed arbitrator, uint256 toFounder, uint256 toTreasury
    );
    event DisputeExpired(uint256 indexed milestoneIndex, IEscrow.MilestoneState priorState);
    event DisputeGraceResumed(uint256 indexed milestoneIndex, uint64 newGraceEndsAt);

    /// @dev A freshly created but uninitialized escrow proxy (factory == 0).
    function _uninitialized() internal returns (Escrow) {
        BeaconProxy proxy = new BeaconProxy(factory.getBeaconProxyAddress(), "");
        return Escrow(address(proxy));
    }

    // =================================================================
    // initialize
    // =================================================================

    function testInitializeSuccessSetsState() public {
        Escrow escrow = _deployDefault();
        assertEq(escrow.factory(), address(factory));
        assertEq(uint8(escrow.escrowState()), uint8(IEscrow.EscrowState.AwaitingAcceptance));
        assertEq(escrow.getEscrowSummary().milestoneCount, 2);
        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Pending));
        assertEq(uint8(escrow.getMilestone(1).state), uint8(IEscrow.MilestoneState.Pending));
    }

    function testInitializeRevertsWhenCallerNotFactory() public {
        Escrow escrow = _uninitialized();
        IEscrow.InitParams memory params = _defaultParams();
        // caller (this test) != factory_ argument
        vm.expectRevert(Errors.OnlyFactory.selector);
        escrow.initialize(params, address(0xdead), FEE_BPS, GRACE, arbitrator);
    }

    function testInitializeRevertsWhenAlreadyInitialized() public {
        Escrow escrow = _deployDefault();
        IEscrow.InitParams memory params = _defaultParams();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(params, address(factory), FEE_BPS, GRACE, arbitrator);
    }

    // =================================================================
    // activateEscrow
    // =================================================================

    function testActivateRevertsNotInitialized() public {
        Escrow escrow = _uninitialized();
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.EscrowNotInitialized.selector);
        escrow.activateEscrow(sigs, block.timestamp + 1 days);
    }

    function testActivateRevertsBadEscrowState() public {
        Escrow escrow = _deployDefault();
        _activate(escrow);
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.BadEscrowState.selector);
        escrow.activateEscrow(sigs, block.timestamp + 1 days);
    }

    function testActivateRevertsSignatureExpired() public {
        vm.warp(1000);
        Escrow escrow = _deployDefault();
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.SignatureExpired.selector);
        escrow.activateEscrow(sigs, block.timestamp - 1);
    }

    function testActivateRevertsBadSignaturesCount() public {
        Escrow escrow = _deployDefault();
        bytes[] memory sigs = new bytes[](1);
        vm.expectRevert(Errors.BadSignatures.selector);
        escrow.activateEscrow(sigs, block.timestamp + 1 days);
    }

    function testActivateRevertsBadFounderSignature() public {
        Escrow escrow = _deployDefault();
        uint256 deadline = block.timestamp + 1 days;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signAcceptance(escrow, strangerPk, deadline); // not founder
        sigs[1] = _signAcceptance(escrow, investorPk, deadline);
        vm.expectRevert(Errors.BadSignature.selector);
        escrow.activateEscrow(sigs, deadline);
    }

    function testActivateRevertsOnSwappedOrder() public {
        Escrow escrow = _deployDefault();
        uint256 deadline = block.timestamp + 1 days;
        bytes[] memory sigs = new bytes[](2);
        // order is [founder, investor]; swap it
        sigs[0] = _signAcceptance(escrow, investorPk, deadline);
        sigs[1] = _signAcceptance(escrow, founderPk, deadline);
        vm.expectRevert(Errors.BadSignature.selector);
        escrow.activateEscrow(sigs, deadline);
    }

    function testActivateSuccess() public {
        Escrow escrow = _deployDefault();
        uint256 deadline = block.timestamp + 1 days;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signAcceptance(escrow, founderPk, deadline);
        sigs[1] = _signAcceptance(escrow, investorPk, deadline);

        vm.expectEmit(false, false, false, true, address(escrow));
        emit EscrowActivated(uint64(block.timestamp));
        escrow.activateEscrow(sigs, deadline);

        assertEq(uint8(escrow.escrowState()), uint8(IEscrow.EscrowState.Active));
        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Active));
        assertEq(escrow.nonces(founder), 1);
        assertEq(escrow.nonces(investor), 1);
    }

    function testActivateReplayFailsAfterNonceAdvances() public {
        Escrow escrow = _deployDefault();
        uint256 deadline = block.timestamp + 1 days;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signAcceptance(escrow, founderPk, deadline);
        sigs[1] = _signAcceptance(escrow, investorPk, deadline);
        escrow.activateEscrow(sigs, deadline);
        // Re-submitting the same signatures now fails on BadEscrowState (already Active).
        vm.expectRevert(Errors.BadEscrowState.selector);
        escrow.activateEscrow(sigs, deadline);
    }

    // =================================================================
    // deposit
    // =================================================================

    function testDepositRevertsNotInitialized() public {
        Escrow escrow = _uninitialized();
        vm.expectRevert(Errors.EscrowNotInitialized.selector);
        escrow.deposit(0);
    }

    function testDepositRevertsEscrowNotActive() public {
        Escrow escrow = _deployDefault();
        vm.expectRevert(Errors.EscrowNotActive.selector);
        escrow.deposit(0);
    }

    function testDepositRevertsDisputeActive() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        vm.expectRevert(Errors.DisputeActive.selector);
        escrow.deposit(0);
    }

    function testDepositRevertsNotCurrentMilestone() public {
        Escrow escrow = _deployDefault();
        _activate(escrow);
        vm.expectRevert(Errors.NotCurrentMilestone.selector);
        escrow.deposit(1);
    }

    function testDepositRevertsNotDepositable() public {
        Escrow escrow = _activeFunded(); // milestone 0 already Funded
        vm.startPrank(investor);
        token.approve(address(escrow), M0);
        vm.expectRevert(Errors.NotDepositable.selector);
        escrow.deposit(0);
        vm.stopPrank();
    }

    function testDepositSuccess() public {
        Escrow escrow = _deployDefault();
        _activate(escrow);

        vm.startPrank(investor);
        token.approve(address(escrow), M0);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit MilestoneDeposited(0, investor, M0);
        escrow.deposit(0);
        vm.stopPrank();

        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Funded));
        assertEq(token.balanceOf(address(escrow)), M0);
    }

    function testDepositAnyAddressCanFund() public {
        Escrow escrow = _deployDefault();
        _activate(escrow);
        // `deposit` has no investor check: a stranger may fund.
        vm.startPrank(stranger);
        token.approve(address(escrow), M0);
        escrow.deposit(0);
        vm.stopPrank();
        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Funded));
    }

    // =================================================================
    // verifyMilestone
    // =================================================================

    function testVerifyRevertsNotInitialized() public {
        Escrow escrow = _uninitialized();
        vm.expectRevert(Errors.EscrowNotInitialized.selector);
        escrow.verifyMilestone(0, EVIDENCE, hex"", block.timestamp + 1);
    }

    function testVerifyRevertsEscrowNotActive() public {
        Escrow escrow = _deployDefault();
        vm.expectRevert(Errors.EscrowNotActive.selector);
        escrow.verifyMilestone(0, EVIDENCE, hex"", block.timestamp + 1);
    }

    function testVerifyRevertsDisputeActive() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        vm.expectRevert(Errors.DisputeActive.selector);
        escrow.verifyMilestone(0, EVIDENCE, hex"", block.timestamp + 1);
    }

    function testVerifyRevertsNotCurrentMilestone() public {
        Escrow escrow = _activeFunded();
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signVerify(escrow, 1, deadline);
        vm.expectRevert(Errors.NotCurrentMilestone.selector);
        escrow.verifyMilestone(1, EVIDENCE, sig, deadline);
    }

    function testVerifyRevertsSignatureExpired() public {
        vm.warp(1000);
        Escrow escrow = _activeFunded();
        vm.expectRevert(Errors.SignatureExpired.selector);
        escrow.verifyMilestone(0, EVIDENCE, hex"", block.timestamp - 1);
    }

    function testVerifyRevertsNotFunded() public {
        Escrow escrow = _deployDefault();
        _activate(escrow); // milestone Active, not Funded
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signVerify(escrow, 0, deadline);
        vm.expectRevert(Errors.NotFunded.selector);
        escrow.verifyMilestone(0, EVIDENCE, sig, deadline);
    }

    function testVerifyRevertsGraceExpired() public {
        Escrow escrow = _activeFunded();
        vm.warp(escrow.getMilestone(0).graceEndsAt + 1);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signVerify(escrow, 0, deadline);
        vm.expectRevert(Errors.GraceExpired.selector);
        escrow.verifyMilestone(0, EVIDENCE, sig, deadline);
    }

    function testVerifyRevertsBadSignature() public {
        Escrow escrow = _activeFunded();
        uint256 deadline = block.timestamp + 1 days;
        // signed by founder, but verify recovers against investor
        bytes memory badSig = _sign(
            escrow,
            founderPk,
            abi.encode(address(escrow), uint256(0), investor, deadline, block.chainid, escrow.nonces(investor))
        );
        vm.expectRevert(Errors.BadSignature.selector);
        escrow.verifyMilestone(0, EVIDENCE, badSig, deadline);
    }

    function testVerifySuccessNotLastMilestone() public {
        Escrow escrow = _activeFunded();
        uint256 deadline = block.timestamp + 1 days;

        vm.expectEmit(true, true, false, true, address(escrow));
        emit MilestoneReleased(0, founder, 39 ether, 1 ether);
        escrow.verifyMilestone(0, EVIDENCE, _signVerify(escrow, 0, deadline), deadline);

        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Released));
        assertEq(escrow.currentMilestoneIndex(), 1);
        assertEq(uint8(escrow.getMilestone(1).state), uint8(IEscrow.MilestoneState.Active));
        assertEq(uint8(escrow.escrowState()), uint8(IEscrow.EscrowState.Active));
        assertEq(token.balanceOf(founder), 39 ether);
        assertEq(token.balanceOf(address(factory)), 1 ether);
    }

    function testVerifySuccessLastMilestoneFinalizes() public {
        Escrow escrow = _deploy(_singleMilestoneParams());
        _activate(escrow);
        _deposit(escrow, 0, investor);
        uint256 deadline = block.timestamp + 1 days;

        escrow.verifyMilestone(0, EVIDENCE, _signVerify(escrow, 0, deadline), deadline);

        assertEq(uint8(escrow.escrowState()), uint8(IEscrow.EscrowState.Finalized));
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // =================================================================
    // renegotiateMilestone
    // =================================================================

    function _renegSigs(Escrow escrow, uint64 nd, uint256 na, bytes32 ndh, uint256 dl)
        internal
        view
        returns (address[] memory signers, bytes[] memory sigs)
    {
        signers = new address[](2);
        signers[0] = founder;
        signers[1] = investor;
        sigs = new bytes[](2);
        sigs[0] = _signReneg(escrow, founderPk, 0, nd, na, ndh, dl);
        sigs[1] = _signReneg(escrow, investorPk, 0, nd, na, ndh, dl);
    }

    function testRenegRevertsNotInitialized() public {
        Escrow escrow = _uninitialized();
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.EscrowNotInitialized.selector);
        escrow.renegotiateMilestone(
            0, uint64(block.timestamp + 1 days), M0, EVIDENCE, signers, sigs, block.timestamp + 1
        );
    }

    function testRenegRevertsEscrowNotActive() public {
        Escrow escrow = _deployDefault();
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.EscrowNotActive.selector);
        escrow.renegotiateMilestone(
            0, uint64(block.timestamp + 1 days), M0, EVIDENCE, signers, sigs, block.timestamp + 1
        );
    }

    function testRenegRevertsDisputeActive() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.DisputeActive.selector);
        escrow.renegotiateMilestone(
            0, uint64(block.timestamp + 1 days), M0, EVIDENCE, signers, sigs, block.timestamp + 1
        );
    }

    function testRenegRevertsNotCurrentMilestone() public {
        Escrow escrow = _activeFunded();
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.NotCurrentMilestone.selector);
        escrow.renegotiateMilestone(
            1, uint64(block.timestamp + 1 days), M0, EVIDENCE, signers, sigs, block.timestamp + 1
        );
    }

    function testRenegRevertsSignatureExpired() public {
        vm.warp(1000);
        Escrow escrow = _activeFunded();
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.SignatureExpired.selector);
        escrow.renegotiateMilestone(
            0, uint64(block.timestamp + 1 days), M0, EVIDENCE, signers, sigs, block.timestamp - 1
        );
    }

    function testRenegRevertsBadDeadline() public {
        Escrow escrow = _activeFunded();
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.BadDeadline.selector);
        escrow.renegotiateMilestone(0, uint64(block.timestamp), M0, EVIDENCE, signers, sigs, block.timestamp + 1 days);
    }

    function testRenegRevertsBadAmount() public {
        Escrow escrow = _activeFunded();
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.BadAmount.selector);
        escrow.renegotiateMilestone(
            0, uint64(block.timestamp + 1 days), 0, EVIDENCE, signers, sigs, block.timestamp + 1 days
        );
    }

    function testRenegRevertsBadDescription() public {
        Escrow escrow = _activeFunded();
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.BadDescription.selector);
        escrow.renegotiateMilestone(
            0, uint64(block.timestamp + 1 days), M0, bytes32(0), signers, sigs, block.timestamp + 1 days
        );
    }

    function testRenegRevertsBadSignaturesCount() public {
        Escrow escrow = _activeFunded();
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](1);
        vm.expectRevert(Errors.BadSignatures.selector);
        escrow.renegotiateMilestone(
            0, uint64(block.timestamp + 1 days), M0, EVIDENCE, signers, sigs, block.timestamp + 1 days
        );
    }

    function testRenegRevertsBadSigners() public {
        Escrow escrow = _activeFunded();
        address[] memory signers = new address[](2);
        signers[0] = stranger; // must be founder
        signers[1] = investor;
        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(Errors.BadSigners.selector);
        escrow.renegotiateMilestone(
            0, uint64(block.timestamp + 1 days), M0, EVIDENCE, signers, sigs, block.timestamp + 1 days
        );
    }

    function testRenegRevertsGraceExpired() public {
        Escrow escrow = _activeFunded();
        vm.warp(escrow.getMilestone(0).graceEndsAt + 1);
        uint64 nd = uint64(block.timestamp + 5 days);
        uint256 dl = block.timestamp + 1 days;
        (address[] memory signers, bytes[] memory sigs) = _renegSigs(escrow, nd, M0, EVIDENCE, dl);
        vm.expectRevert(Errors.GraceExpired.selector);
        escrow.renegotiateMilestone(0, nd, M0, EVIDENCE, signers, sigs, dl);
    }

    function testRenegRevertsBadSignature() public {
        Escrow escrow = _activeFunded();
        uint64 nd = uint64(block.timestamp + 5 days);
        uint256 dl = block.timestamp + 1 days;
        address[] memory signers = new address[](2);
        signers[0] = founder;
        signers[1] = investor;
        bytes[] memory sigs = new bytes[](2);
        // founder slot signed by stranger
        sigs[0] = _signReneg(escrow, strangerPk, 0, nd, M0, EVIDENCE, dl);
        sigs[1] = _signReneg(escrow, investorPk, 0, nd, M0, EVIDENCE, dl);
        vm.expectRevert(Errors.BadSignature.selector);
        escrow.renegotiateMilestone(0, nd, M0, EVIDENCE, signers, sigs, dl);
    }

    function testRenegSuccessUnfundedStaysActive() public {
        Escrow escrow = _deployDefault();
        _activate(escrow); // milestone Active, no deposit
        uint64 nd = uint64(block.timestamp + 5 days);
        uint256 dl = block.timestamp + 1 days;
        uint256 newAmount = 42 ether;
        bytes32 ndh = keccak256("v2");
        (address[] memory signers, bytes[] memory sigs) = _renegSigs(escrow, nd, newAmount, ndh, dl);

        escrow.renegotiateMilestone(0, nd, newAmount, ndh, signers, sigs, dl);

        IEscrow.Milestone memory m = escrow.getMilestone(0);
        assertEq(uint8(m.state), uint8(IEscrow.MilestoneState.Active));
        assertEq(m.amount, newAmount);
        assertEq(m.deadline, nd);
        assertEq(m.graceEndsAt, nd + GRACE);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testRenegSuccessFundedSmallerRefundsExcess() public {
        Escrow escrow = _activeFunded(); // funded 40
        uint64 nd = uint64(block.timestamp + 5 days);
        uint256 dl = block.timestamp + 1 days;
        uint256 newAmount = 30 ether;
        bytes32 ndh = keccak256("v2");
        (address[] memory signers, bytes[] memory sigs) = _renegSigs(escrow, nd, newAmount, ndh, dl);

        uint256 before = token.balanceOf(investor);
        escrow.renegotiateMilestone(0, nd, newAmount, ndh, signers, sigs, dl);

        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Funded));
        assertEq(token.balanceOf(investor), before + 10 ether);
        assertEq(token.balanceOf(address(escrow)), newAmount);
    }

    function testRenegSuccessFundedEqualNoTransfer() public {
        Escrow escrow = _activeFunded();
        uint64 nd = uint64(block.timestamp + 5 days);
        uint256 dl = block.timestamp + 1 days;
        bytes32 ndh = keccak256("v2");
        (address[] memory signers, bytes[] memory sigs) = _renegSigs(escrow, nd, M0, ndh, dl);

        uint256 before = token.balanceOf(investor);
        escrow.renegotiateMilestone(0, nd, M0, ndh, signers, sigs, dl);

        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Funded));
        assertEq(token.balanceOf(investor), before);
        assertEq(token.balanceOf(address(escrow)), M0);
    }

    function testRenegSuccessFundedLargerReturnsAndRequiresRedeposit() public {
        Escrow escrow = _activeFunded(); // funded 40
        uint64 nd = uint64(block.timestamp + 5 days);
        uint256 dl = block.timestamp + 1 days;
        uint256 newAmount = 50 ether;
        bytes32 ndh = keccak256("v2");
        (address[] memory signers, bytes[] memory sigs) = _renegSigs(escrow, nd, newAmount, ndh, dl);

        uint256 before = token.balanceOf(investor);
        escrow.renegotiateMilestone(0, nd, newAmount, ndh, signers, sigs, dl);

        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Active));
        assertEq(token.balanceOf(investor), before + M0); // full old amount returned
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // =================================================================
    // claimRefund
    // =================================================================

    function testClaimRefundRevertsNotInitialized() public {
        Escrow escrow = _uninitialized();
        vm.expectRevert(Errors.EscrowNotInitialized.selector);
        escrow.claimRefund(0);
    }

    function testClaimRefundRevertsEscrowNotActive() public {
        Escrow escrow = _deployDefault();
        vm.prank(investor);
        vm.expectRevert(Errors.EscrowNotActive.selector);
        escrow.claimRefund(0);
    }

    function testClaimRefundRevertsDisputeActive() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        vm.prank(investor);
        vm.expectRevert(Errors.DisputeActive.selector);
        escrow.claimRefund(0);
    }

    function testClaimRefundRevertsOnlyInvestor() public {
        Escrow escrow = _activeFunded();
        vm.prank(stranger);
        vm.expectRevert(Errors.OnlyInvestor.selector);
        escrow.claimRefund(0);
    }

    function testClaimRefundRevertsNotCurrentMilestone() public {
        Escrow escrow = _activeFunded();
        vm.prank(investor);
        vm.expectRevert(Errors.NotCurrentMilestone.selector);
        escrow.claimRefund(1);
    }

    function testClaimRefundRevertsNotRefundable() public {
        Escrow escrow = _deployDefault();
        _activate(escrow); // milestone Active (unfunded)
        vm.prank(investor);
        vm.expectRevert(Errors.NotRefundable.selector);
        escrow.claimRefund(0);
    }

    function testClaimRefundRevertsGraceActiveAtBoundary() public {
        Escrow escrow = _activeFunded();
        // boundary now == graceEndsAt is still GraceActive (needs strict >)
        vm.warp(escrow.getMilestone(0).graceEndsAt);
        vm.prank(investor);
        vm.expectRevert(Errors.GraceActive.selector);
        escrow.claimRefund(0);
    }

    function testClaimRefundSuccessAdvancesToNext() public {
        Escrow escrow = _activeFunded();
        vm.warp(escrow.getMilestone(0).graceEndsAt + 1);
        uint256 before = token.balanceOf(investor);

        vm.prank(investor);
        escrow.claimRefund(0);

        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Refunded));
        assertEq(token.balanceOf(investor), before + M0);
        assertEq(escrow.currentMilestoneIndex(), 1);
        assertEq(uint8(escrow.getMilestone(1).state), uint8(IEscrow.MilestoneState.Active));
        assertEq(uint8(escrow.escrowState()), uint8(IEscrow.EscrowState.Active));
    }

    function testClaimRefundSuccessLastMilestoneCancels() public {
        Escrow escrow = _deploy(_singleMilestoneParams());
        _activate(escrow);
        _deposit(escrow, 0, investor);
        vm.warp(escrow.getMilestone(0).graceEndsAt + 1);

        vm.expectEmit(false, false, false, true, address(escrow));
        emit EscrowCancelled(uint64(block.timestamp));
        vm.prank(investor);
        escrow.claimRefund(0);

        assertEq(uint8(escrow.escrowState()), uint8(IEscrow.EscrowState.Cancelled));
        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Refunded));
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // =================================================================
    // createDispute
    // =================================================================

    /// @dev Funds milestone 0, warps into the dispute window, opens a dispute as the founder.
    function _openDispute(Escrow escrow) internal {
        vm.warp(escrow.getMilestone(0).deadline + 1);
        vm.prank(founder);
        escrow.createDispute(0, EVIDENCE);
    }

    function testCreateDisputeRevertsNotInitialized() public {
        Escrow escrow = _uninitialized();
        vm.expectRevert(Errors.EscrowNotInitialized.selector);
        escrow.createDispute(0, EVIDENCE);
    }

    function testCreateDisputeRevertsEscrowNotActive() public {
        Escrow escrow = _deployDefault();
        vm.expectRevert(Errors.EscrowNotActive.selector);
        escrow.createDispute(0, EVIDENCE);
    }

    function testCreateDisputeRevertsDisputeActive() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        vm.prank(founder);
        vm.expectRevert(Errors.DisputeActive.selector);
        escrow.createDispute(0, EVIDENCE);
    }

    function testCreateDisputeRevertsUnauthorized() public {
        Escrow escrow = _activeFunded();
        vm.warp(escrow.getMilestone(0).deadline + 1);
        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        escrow.createDispute(0, EVIDENCE);
    }

    function testCreateDisputeRevertsEmptyEvidence() public {
        Escrow escrow = _activeFunded();
        vm.warp(escrow.getMilestone(0).deadline + 1);
        vm.prank(founder);
        vm.expectRevert(Errors.EmptyEvidence.selector);
        escrow.createDispute(0, bytes32(0));
    }

    function testCreateDisputeRevertsNotCurrentMilestone() public {
        Escrow escrow = _activeFunded();
        vm.warp(escrow.getMilestone(0).deadline + 1);
        vm.prank(founder);
        vm.expectRevert(Errors.NotCurrentMilestone.selector);
        escrow.createDispute(1, EVIDENCE);
    }

    function testCreateDisputeRevertsBadMilestoneStateWhenUnfunded() public {
        Escrow escrow = _deployDefault();
        _activate(escrow); // milestone Active (unfunded)
        vm.warp(escrow.getMilestone(0).deadline + 1);
        vm.prank(founder);
        vm.expectRevert(Errors.BadMilestoneState.selector);
        escrow.createDispute(0, EVIDENCE);
    }

    function testCreateDisputeRevertsOutsideWindowPre() public {
        Escrow escrow = _activeFunded();
        // now <= deadline
        vm.prank(founder);
        vm.expectRevert(Errors.OutsideDisputeWindow.selector);
        escrow.createDispute(0, EVIDENCE);
    }

    function testCreateDisputeRevertsOutsideWindowPost() public {
        Escrow escrow = _activeFunded();
        vm.warp(escrow.getMilestone(0).graceEndsAt + 1);
        vm.prank(founder);
        vm.expectRevert(Errors.OutsideDisputeWindow.selector);
        escrow.createDispute(0, EVIDENCE);
    }

    function testCreateDisputeSuccess() public {
        Escrow escrow = _activeFunded();
        uint64 graceEndsAt = escrow.getMilestone(0).graceEndsAt;
        vm.warp(escrow.getMilestone(0).deadline + 1);
        uint64 nowTs = uint64(block.timestamp);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit DisputeCreated(0, founder, EVIDENCE, nowTs + 7 days);
        vm.prank(founder);
        escrow.createDispute(0, EVIDENCE);

        IEscrow.DisputeInfo memory d = escrow.getDisputeInfo(0);
        assertEq(d.openedAt, nowTs);
        assertEq(d.endsAt, nowTs + 7 days);
        assertEq(d.graceRemaining, graceEndsAt - nowTs);
        assertEq(uint8(d.priorState), uint8(IEscrow.MilestoneState.Funded));
        assertEq(d.initiator, founder);
        assertEq(d.evidenceHash, EVIDENCE);
    }

    function testCreateDisputeInvestorCanInitiate() public {
        Escrow escrow = _activeFunded();
        vm.warp(escrow.getMilestone(0).deadline + 1);
        vm.prank(investor);
        escrow.createDispute(0, EVIDENCE);
        assertEq(escrow.getDisputeInfo(0).initiator, investor);
    }

    // =================================================================
    // resolveDisputeByArbitrator
    // =================================================================

    function testResolveByArbitratorRevertsNotInitialized() public {
        Escrow escrow = _uninitialized();
        vm.prank(arbitrator);
        vm.expectRevert(Errors.EscrowNotInitialized.selector);
        escrow.resolveDisputeByArbitrator(0, true);
    }

    function testResolveByArbitratorRevertsOnlyArbitrator() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        vm.prank(stranger);
        vm.expectRevert(Errors.OnlyArbitrator.selector);
        escrow.resolveDisputeByArbitrator(0, true);
    }

    function testResolveByArbitratorRevertsNoDispute() public {
        Escrow escrow = _activeFunded();
        vm.prank(arbitrator);
        vm.expectRevert(Errors.NoDispute.selector);
        escrow.resolveDisputeByArbitrator(0, true);
    }

    function testResolveByArbitratorRevertsGraceExpired() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        vm.warp(escrow.getDisputeInfo(0).endsAt + 1);
        vm.prank(arbitrator);
        vm.expectRevert(Errors.GraceExpired.selector);
        escrow.resolveDisputeByArbitrator(0, true);
    }

    function testResolveByArbitratorReleaseToFounder() public {
        Escrow escrow = _deploy(_singleMilestoneParams());
        _activate(escrow);
        _deposit(escrow, 0, investor);
        vm.warp(escrow.getMilestone(0).deadline + 1);
        vm.prank(founder);
        escrow.createDispute(0, EVIDENCE);

        uint256 fee = M0 * FEE_BPS / 10_000;
        vm.expectEmit(true, true, false, true, address(escrow));
        emit MilestoneForceReleased(0, arbitrator, M0 - fee, fee);
        vm.prank(arbitrator);
        escrow.resolveDisputeByArbitrator(0, true);

        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Released));
        assertEq(uint8(escrow.escrowState()), uint8(IEscrow.EscrowState.Finalized));
        assertEq(escrow.getDisputeInfo(0).openedAt, 0);
        assertEq(token.balanceOf(founder), M0 - fee);
        assertEq(token.balanceOf(address(factory)), fee);
    }

    function testResolveByArbitratorReleaseToInvestor() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        IEscrow.DisputeInfo memory d = escrow.getDisputeInfo(0);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit DisputeGraceResumed(0, uint64(block.timestamp) + d.graceRemaining);
        vm.prank(arbitrator);
        escrow.resolveDisputeByArbitrator(0, false);

        IEscrow.Milestone memory m = escrow.getMilestone(0);
        assertEq(uint8(m.state), uint8(IEscrow.MilestoneState.Refundable));
        assertEq(m.graceEndsAt, uint64(block.timestamp) + d.graceRemaining);
        assertEq(escrow.getDisputeInfo(0).openedAt, 0);
        // deposit still held
        assertEq(token.balanceOf(address(escrow)), M0);
    }

    function testResolveByArbitratorBoundaryAtEndsAt() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        // now == endsAt is still resolvable (> check)
        vm.warp(escrow.getDisputeInfo(0).endsAt);
        vm.prank(arbitrator);
        escrow.resolveDisputeByArbitrator(0, false);
        assertEq(uint8(escrow.getMilestone(0).state), uint8(IEscrow.MilestoneState.Refundable));
    }

    // =================================================================
    // resolveExpiredDispute
    // =================================================================

    function testResolveExpiredRevertsNotInitialized() public {
        Escrow escrow = _uninitialized();
        vm.expectRevert(Errors.EscrowNotInitialized.selector);
        escrow.resolveExpiredDispute(0);
    }

    function testResolveExpiredRevertsNoDispute() public {
        Escrow escrow = _activeFunded();
        vm.expectRevert(Errors.NoDispute.selector);
        escrow.resolveExpiredDispute(0);
    }

    function testResolveExpiredRevertsDisputeActiveBoundary() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        // now == endsAt ⇒ still DisputeActive (needs strict >)
        vm.warp(escrow.getDisputeInfo(0).endsAt);
        vm.expectRevert(Errors.DisputeActive.selector);
        escrow.resolveExpiredDispute(0);
    }

    function testResolveExpiredSuccessPermissionless() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        IEscrow.DisputeInfo memory d = escrow.getDisputeInfo(0);
        vm.warp(d.endsAt + 1);

        uint64 expectedGrace = uint64(block.timestamp) + d.graceRemaining;
        vm.expectEmit(true, false, false, true, address(escrow));
        emit DisputeExpired(0, IEscrow.MilestoneState.Funded);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit DisputeGraceResumed(0, expectedGrace);
        // anyone may call
        vm.prank(stranger);
        escrow.resolveExpiredDispute(0);

        IEscrow.Milestone memory m = escrow.getMilestone(0);
        assertEq(uint8(m.state), uint8(IEscrow.MilestoneState.Refundable));
        assertEq(m.graceEndsAt, expectedGrace);
        assertEq(escrow.getDisputeInfo(0).openedAt, 0);
        assertEq(token.balanceOf(address(escrow)), M0);
    }

    /// @dev End-to-end: a dispute ruled for the investor leaves a Refundable milestone whose deposit
    ///      is still held, so claimRefund succeeds (the fixed unfunded-dispute defect).
    function testRefundableFromDisputeIsBackedByDeposit() public {
        Escrow escrow = _activeFunded();
        _openDispute(escrow);
        vm.prank(arbitrator);
        escrow.resolveDisputeByArbitrator(0, false);

        vm.warp(escrow.getMilestone(0).graceEndsAt + 1);
        uint256 before = token.balanceOf(investor);
        vm.prank(investor);
        escrow.claimRefund(0);
        assertEq(token.balanceOf(investor), before + M0);
    }

    // =================================================================
    // Views
    // =================================================================

    function testGetEscrowSummary() public {
        Escrow escrow = _activeFunded();
        uint256 deadline = block.timestamp + 1 days;
        escrow.verifyMilestone(0, EVIDENCE, _signVerify(escrow, 0, deadline), deadline);

        IEscrow.EscrowSummary memory s = escrow.getEscrowSummary();
        assertEq(s.totalAmount, TOTAL);
        assertEq(s.totalReleased, M0);
        assertEq(s.totalAccounted, M0);
        assertEq(s.milestoneCount, 2);
        assertEq(s.currentMilestoneIndex, 1);
        assertEq(s.feeBps, FEE_BPS);
        assertEq(s.gracePeriod, GRACE);
    }

    function testGetMilestoneRevertsOutOfRange() public {
        Escrow escrow = _deployDefault();
        vm.expectRevert(Errors.BadMilestone.selector);
        escrow.getMilestone(2);
    }

    function testGetDisputeInfoRevertsOutOfRange() public {
        Escrow escrow = _deployDefault();
        vm.expectRevert(Errors.BadMilestone.selector);
        escrow.getDisputeInfo(2);
    }

    function testGetDisputeInfoZeroedWhenNoDispute() public {
        Escrow escrow = _deployDefault();
        IEscrow.DisputeInfo memory d = escrow.getDisputeInfo(0);
        assertEq(d.openedAt, 0);
        assertEq(d.initiator, address(0));
    }

    // =================================================================
    // Fuzz
    // =================================================================

    /// @dev For any allowed fee/grace and milestone amount, release conserves value:
    ///      founderAmount + feeAmount == amount, with fee <= amount/10.
    function testFuzzReleaseConservesValue(uint256 amount, uint16 feeBps) public {
        amount = bound(amount, 1, 1_000_000 ether);
        feeBps = uint16(bound(feeBps, 0, 1000));

        // Reconfigure the factory default fee, then deploy a fresh single-milestone escrow.
        factory.setDefaultFeeRate(feeBps);
        IEscrow.InitParams memory params = _singleMilestoneParams();
        params.totalAmount = amount;
        params.milestoneAmounts[0] = amount;
        Escrow escrow = _deploy(params);
        _activate(escrow);
        _deposit(escrow, 0, investor);

        uint256 founderBefore = token.balanceOf(founder);
        uint256 factoryBefore = token.balanceOf(address(factory));

        uint256 deadline = block.timestamp + 1 days;
        escrow.verifyMilestone(0, EVIDENCE, _signVerify(escrow, 0, deadline), deadline);

        uint256 paidFounder = token.balanceOf(founder) - founderBefore;
        uint256 paidFee = token.balanceOf(address(factory)) - factoryBefore;
        assertEq(paidFounder + paidFee, amount);
        assertLe(paidFee, amount / 10);
        assertEq(token.balanceOf(address(escrow)), 0);
    }
}
