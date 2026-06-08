// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IEscrow} from "./interfaces/IEscrow.sol";
import {Errors} from "./lib/Errors.sol";
import {Helpers} from "./lib/Helpers.sol";
import {VerifySignature} from "./lib/VerifySignature.sol";

contract Escrow is IEscrow, Initializable, VerifySignature, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant DISPUTE_WINDOW = 7 days;

    address public override factory;
    address public founder;
    address public investor;
    address public override token;
    address public arbitrator;
    uint256 public currentMilestoneIndex;
    uint16 public feeBps;
    uint32 public gracePeriod;

    EscrowState public escrowState;

    mapping(address => uint256) public nonces;

    Milestone[] private _milestones;

    mapping(uint256 milestoneIndex => DisputeInfo dispute) private _disputes;

    constructor() {
        _disableInitializers();
    }

    modifier onlyInitialized() {
        if (factory == address(0)) revert Errors.EscrowNotInitialized();
        _;
    }

    modifier onlyActiveEscrow() {
        if (escrowState != EscrowState.Active) revert Errors.EscrowNotActive();
        _;
    }

    modifier noActiveDispute(uint256 milestoneIndex) {
        if (_disputes[milestoneIndex].openedAt != 0) revert Errors.DisputeActive();
        _;
    }

    function initialize(
        InitParams calldata params,
        address factory_,
        uint16 feeBps_,
        uint32 gracePeriod_,
        address arbitrator_
    ) external override initializer {
        if (msg.sender != factory_) revert Errors.OnlyFactory();

        factory = factory_;
        founder = params.founder;
        investor = params.investor;
        token = params.token;
        arbitrator = arbitrator_;
        feeBps = feeBps_;
        gracePeriod = gracePeriod_;
        escrowState = EscrowState.AwaitingAcceptance;

        for (uint256 i = 0; i < params.milestoneAmounts.length; i++) {
            _milestones.push(
                Milestone({
                    amount: params.milestoneAmounts[i],
                    deadline: params.milestoneDeadlines[i],
                    graceEndsAt: params.milestoneDeadlines[i] + gracePeriod_,
                    state: MilestoneState.Pending,
                    descriptionHash: params.milestoneDescriptionHashes[i]
                })
            );
        }

        emit EscrowCreated(params.founder, params.token, params.totalAmount, params.milestoneAmounts.length);
    }

    function activateEscrow(bytes[] calldata signatures, uint256 deadline) external override onlyInitialized {
        if (escrowState != EscrowState.AwaitingAcceptance) revert Errors.BadEscrowState();
        if (block.timestamp > deadline) revert Errors.SignatureExpired();
        if (signatures.length != 2) revert Errors.BadSignatures();

        _verifyAcceptance(founder, signatures[0], deadline);
        _verifyAcceptance(investor, signatures[1], deadline);

        escrowState = EscrowState.Active;
        _milestones[0].state = MilestoneState.Active;

        emit EscrowActivated(uint64(block.timestamp));
    }

    function deposit(uint256 milestoneIndex)
        external
        override
        onlyInitialized
        onlyActiveEscrow
        noActiveDispute(milestoneIndex)
        nonReentrant
    {
        if (milestoneIndex != currentMilestoneIndex) revert Errors.NotCurrentMilestone();

        Milestone storage milestone = _milestones[milestoneIndex];
        if (milestone.state != MilestoneState.Active) revert Errors.NotDepositable();

        uint256 amount = milestone.amount;
        milestone.state = MilestoneState.Funded;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit MilestoneDeposited(milestoneIndex, msg.sender, amount);
    }

    function verifyMilestone(uint256 milestoneIndex, bytes32 evidenceHash, bytes calldata signature, uint256 deadline)
        external
        override
        onlyInitialized
        onlyActiveEscrow
        noActiveDispute(milestoneIndex)
        nonReentrant
    {
        if (milestoneIndex != currentMilestoneIndex) revert Errors.NotCurrentMilestone();
        if (block.timestamp > deadline) revert Errors.SignatureExpired();

        Milestone storage milestone = _milestones[milestoneIndex];
        if (milestone.state != MilestoneState.Funded) revert Errors.NotFunded();
        if (block.timestamp > milestone.graceEndsAt) revert Errors.GraceExpired();

        _verifyMilestoneSignature(milestoneIndex, signature, deadline);

        milestone.state = MilestoneState.Verified;
        emit MilestoneVerified(milestoneIndex, investor, evidenceHash);

        _releaseMilestone(milestoneIndex);
    }

    function renegotiateMilestone(
        uint256 milestoneIndex,
        uint64 newDeadline,
        uint256 newAmount,
        bytes32 newDescriptionHash,
        address[] calldata signers,
        bytes[] calldata signatures,
        uint256 deadline
    ) external override onlyInitialized onlyActiveEscrow noActiveDispute(milestoneIndex) nonReentrant {
        if (milestoneIndex != currentMilestoneIndex) revert Errors.NotCurrentMilestone();
        if (block.timestamp > deadline) revert Errors.SignatureExpired();
        if (newDeadline <= block.timestamp) revert Errors.BadDeadline();
        if (newAmount == 0) revert Errors.BadAmount();
        if (newDescriptionHash == bytes32(0)) revert Errors.BadDescription();
        if (signers.length != 2 || signatures.length != 2) revert Errors.BadSignatures();
        if (signers[0] != founder || signers[1] != investor) revert Errors.BadSigners();

        Milestone storage milestone = _milestones[milestoneIndex];
        if (!Helpers.isRenegotiable(milestone.state)) revert Errors.NotRenegotiable();
        if (block.timestamp > milestone.graceEndsAt) revert Errors.GraceExpired();

        RenegotiationTerms memory terms = RenegotiationTerms({
            milestoneIndex: milestoneIndex,
            newDeadline: newDeadline,
            newAmount: newAmount,
            newDescriptionHash: newDescriptionHash,
            deadline: deadline
        });

        _verifyRenegotiation(founder, signatures[0], terms);
        _verifyRenegotiation(investor, signatures[1], terms);

        // Funded and Refundable both imply the contract is holding a live deposit of `oldAmount`;
        // Active does not.
        bool hasDeposit = milestone.state == MilestoneState.Funded || milestone.state == MilestoneState.Refundable;
        uint256 oldAmount = milestone.amount;

        milestone.amount = newAmount;
        milestone.deadline = newDeadline;
        // Fresh deadline resets grace from scratch, discarding any dispute-resumed window.
        milestone.graceEndsAt = newDeadline + gracePeriod;
        milestone.descriptionHash = newDescriptionHash;

        if (!hasDeposit) {
            // Nothing deposited yet: the new terms must be funded from scratch.
            milestone.state = MilestoneState.Active;
        } else if (newAmount <= oldAmount) {
            // Existing deposit still covers the (smaller-or-equal) target; refund the freed excess.
            milestone.state = MilestoneState.Funded;
            if (oldAmount > newAmount) IERC20(token).safeTransfer(investor, oldAmount - newAmount);
        } else {
            // Existing deposit no longer covers the larger target; return it and require a fresh deposit.
            milestone.state = MilestoneState.Active;
            IERC20(token).safeTransfer(investor, oldAmount);
        }

        emit MilestoneRenegotiated(milestoneIndex, newDeadline, newAmount, newDescriptionHash);
    }

    function claimRefund(uint256 milestoneIndex)
        external
        override
        onlyInitialized
        onlyActiveEscrow
        noActiveDispute(milestoneIndex)
        nonReentrant
    {
        if (msg.sender != investor) revert Errors.OnlyInvestor();
        if (milestoneIndex != currentMilestoneIndex) revert Errors.NotCurrentMilestone();

        Milestone storage milestone = _milestones[milestoneIndex];
        if (milestone.state != MilestoneState.Funded && milestone.state != MilestoneState.Refundable) {
            revert Errors.NotRefundable();
        }
        if (block.timestamp <= milestone.graceEndsAt) revert Errors.GraceActive();

        uint256 refundAmount = milestone.amount;
        milestone.state = MilestoneState.Refunded;

        IERC20(token).safeTransfer(investor, refundAmount);

        emit MilestoneRefunded(milestoneIndex, investor, refundAmount);
        _advance(EscrowState.Cancelled);
    }

    function createDispute(uint256 milestoneIndex, bytes32 evidenceHash)
        external
        override
        onlyInitialized
        onlyActiveEscrow
        noActiveDispute(milestoneIndex)
    {
        if (msg.sender != founder && msg.sender != investor) revert Errors.Unauthorized();
        if (evidenceHash == bytes32(0)) revert Errors.EmptyEvidence();
        if (milestoneIndex != currentMilestoneIndex) revert Errors.NotCurrentMilestone();

        Milestone storage milestone = _milestones[milestoneIndex];
        if (milestone.state != MilestoneState.Funded) revert Errors.BadMilestoneState();
        uint64 graceEndsAt = milestone.graceEndsAt;
        if (block.timestamp <= milestone.deadline || block.timestamp > graceEndsAt) {
            revert Errors.OutsideDisputeWindow();
        }

        uint64 openedAt = uint64(block.timestamp);
        uint64 endsAt = openedAt + DISPUTE_WINDOW;
        _disputes[milestoneIndex] = DisputeInfo({
            openedAt: openedAt,
            endsAt: endsAt,
            graceRemaining: graceEndsAt - openedAt,
            priorState: milestone.state,
            initiator: msg.sender,
            evidenceHash: evidenceHash
        });

        emit DisputeCreated(milestoneIndex, msg.sender, evidenceHash, endsAt);
    }

    function resolveDisputeByArbitrator(uint256 milestoneIndex, bool releaseToFounder)
        external
        override
        onlyInitialized
        nonReentrant
    {
        if (msg.sender != arbitrator) revert Errors.OnlyArbitrator();

        DisputeInfo memory dispute = _disputes[milestoneIndex];
        if (dispute.openedAt == 0) revert Errors.NoDispute();
        if (block.timestamp > dispute.endsAt) revert Errors.GraceExpired();

        delete _disputes[milestoneIndex];

        Milestone storage milestone = _milestones[milestoneIndex];

        if (releaseToFounder) {
            if (dispute.priorState != MilestoneState.Funded) revert Errors.NotFunded();

            (uint256 founderAmount, uint256 feeAmount) = _settleRelease(milestoneIndex);

            emit MilestoneForceReleased(milestoneIndex, arbitrator, founderAmount, feeAmount);
            _advance(EscrowState.Finalized);
        } else {
            milestone.state = MilestoneState.Refundable;
            uint64 newGraceEndsAt = uint64(block.timestamp) + dispute.graceRemaining;
            milestone.graceEndsAt = newGraceEndsAt;
            emit DisputeGraceResumed(milestoneIndex, newGraceEndsAt);
        }
    }

    function resolveExpiredDispute(uint256 milestoneIndex) external override onlyInitialized {
        DisputeInfo memory dispute = _disputes[milestoneIndex];
        if (dispute.openedAt == 0) revert Errors.NoDispute();
        if (block.timestamp <= dispute.endsAt) revert Errors.DisputeActive();

        delete _disputes[milestoneIndex];

        Milestone storage milestone = _milestones[milestoneIndex];
        milestone.state = MilestoneState.Refundable;

        uint64 newGraceEndsAt = uint64(block.timestamp) + dispute.graceRemaining;
        milestone.graceEndsAt = newGraceEndsAt;

        emit DisputeExpired(milestoneIndex, dispute.priorState);
        emit DisputeGraceResumed(milestoneIndex, newGraceEndsAt);
    }

    function getEscrowSummary() external view override returns (EscrowSummary memory summary) {
        uint256 totalAmount;
        uint256 totalReleased;
        uint256 totalAccounted;

        for (uint256 i = 0; i < _milestones.length; i++) {
            totalAmount += _milestones[i].amount;
            if (_milestones[i].state == MilestoneState.Released) {
                totalReleased += _milestones[i].amount;
                totalAccounted += _milestones[i].amount;
            } else if (_milestones[i].state == MilestoneState.Refunded) {
                totalAccounted += _milestones[i].amount;
            }
        }

        summary = EscrowSummary({
            founder: founder,
            token: token,
            totalAmount: totalAmount,
            totalReleased: totalReleased,
            totalAccounted: totalAccounted,
            milestoneCount: _milestones.length,
            currentMilestoneIndex: currentMilestoneIndex,
            escrowState: escrowState,
            feeBps: feeBps,
            gracePeriod: gracePeriod
        });
    }

    function getMilestone(uint256 milestoneIndex) external view override returns (Milestone memory milestone) {
        if (milestoneIndex >= _milestones.length) revert Errors.BadMilestone();
        return _milestones[milestoneIndex];
    }

    function getDisputeInfo(uint256 milestoneIndex) external view override returns (DisputeInfo memory info) {
        if (milestoneIndex >= _milestones.length) revert Errors.BadMilestone();
        return _disputes[milestoneIndex];
    }

    function _releaseMilestone(uint256 milestoneIndex) private {
        (uint256 founderAmount, uint256 feeAmount) = _settleRelease(milestoneIndex);

        emit MilestoneReleased(milestoneIndex, founder, founderAmount, feeAmount);
        _advance(EscrowState.Finalized);
    }

    /// @dev Marks the milestone Released and pays the founder net of fee, forwarding the fee to the
    ///      factory. Shared by the verification (`verifyMilestone`) and arbitrator force-release paths.
    function _settleRelease(uint256 milestoneIndex) private returns (uint256 founderAmount, uint256 feeAmount) {
        Milestone storage milestone = _milestones[milestoneIndex];
        uint256 amount = milestone.amount;

        feeAmount = Helpers.calculateFee(amount, feeBps);
        founderAmount = amount - feeAmount;

        milestone.state = MilestoneState.Released;

        if (founderAmount > 0) IERC20(token).safeTransfer(founder, founderAmount);
        if (feeAmount > 0) {
            IERC20(token).safeTransfer(factory, feeAmount);
            emit FeeCollected(milestoneIndex, factory, feeAmount);
        }
    }

    /// @dev Advances to the next milestone, or terminates the escrow in `terminalState` when none
    ///      remain — Finalized after a release, Cancelled (with event) after a refund drain.
    function _advance(EscrowState terminalState) private {
        if (currentMilestoneIndex + 1 == _milestones.length) {
            escrowState = terminalState;
            if (terminalState == EscrowState.Cancelled) emit EscrowCancelled(uint64(block.timestamp));
        } else {
            currentMilestoneIndex++;
            _milestones[currentMilestoneIndex].state = MilestoneState.Active;
        }
    }

    function _verifyAcceptance(address signer, bytes calldata signature, uint256 deadline) private {
        _consumeSignature(
            signer, signature, abi.encode(address(this), founder, investor, deadline, block.chainid, nonces[signer])
        );
    }

    function _verifyMilestoneSignature(uint256 milestoneIndex, bytes calldata signature, uint256 deadline) private {
        _consumeSignature(
            investor,
            signature,
            abi.encode(address(this), milestoneIndex, investor, deadline, block.chainid, nonces[investor])
        );
    }

    function _verifyRenegotiation(address signer, bytes calldata signature, RenegotiationTerms memory terms) private {
        bytes memory encoded = abi.encode(
            address(this),
            terms.milestoneIndex,
            terms.newDeadline,
            terms.newAmount,
            terms.newDescriptionHash,
            signer,
            terms.deadline,
            block.chainid,
            nonces[signer]
        );

        _consumeSignature(signer, signature, encoded);
    }

    /// @dev Recovers the EIP-191 `personal_sign` signature over `encoded`, requires it to match
    ///      `signer`, and consumes that signer's nonce.
    function _consumeSignature(address signer, bytes calldata signature, bytes memory encoded) private {
        if (_recoverValidSignature(getSignedHash(bytesToString(encoded)), signature) != signer) {
            revert Errors.BadSignature();
        }

        nonces[signer]++;
    }
}
