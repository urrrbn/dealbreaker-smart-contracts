// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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

    struct RenegotiationTerms {
        uint256 milestoneIndex;
        uint64 newDeadline;
        uint256 newAmount;
        bytes32 newDescriptionHash;
        uint256 deadline;
    }

    uint256 private constant SECP256K1_HALF_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
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
                    state: uint8(MilestoneState.Pending),
                    descriptionHash: params.milestoneDescriptionHashes[i]
                })
            );
        }

        emit EscrowCreated(params.founder, params.token, params.totalAmount, params.milestoneAmounts.length);
    }

    // okay
    function activateEscrow(
        bytes[] calldata signatures, 
        uint256 deadline
    ) external override onlyInitialized {
        if (escrowState != EscrowState.AwaitingAcceptance) revert Errors.BadEscrowState();
        if (block.timestamp > deadline) revert Errors.SignatureExpired();
        if (signatures.length != 2) revert Errors.BadSignatures();

        _verifyAcceptance(founder, signatures[0], deadline);
        _verifyAcceptance(investor, signatures[1], deadline);

        escrowState = EscrowState.Active;
        _milestones[0].state = uint8(MilestoneState.Active);

        emit EscrowActivated(uint64(block.timestamp));
    }

    // okay
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
        if (milestone.state != uint8(MilestoneState.Active)) revert Errors.NotDepositable();

        uint256 amount = milestone.amount;
        milestone.state = uint8(MilestoneState.Funded);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit MilestoneDeposited(milestoneIndex, msg.sender, amount);
    }
    
    // okay
    function verifyMilestone(
        uint256 milestoneIndex,
        bytes calldata signature,
        uint256 deadline
    ) 
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
        if (milestone.state != uint8(MilestoneState.Funded)) revert Errors.NotFunded();
        if (block.timestamp > milestone.deadline + gracePeriod) revert Errors.GraceExpired();

        _verifyMilestoneSignature(milestoneIndex, signature, deadline);

        milestone.state = uint8(MilestoneState.Verified);
        emit MilestoneVerified(milestoneIndex, investor);

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
    ) 
        external 
        override 
        onlyInitialized 
        onlyActiveEscrow 
        noActiveDispute(milestoneIndex) 
        nonReentrant
    {
        if (milestoneIndex != currentMilestoneIndex) revert Errors.NotCurrentMilestone();
        if (block.timestamp > deadline) revert Errors.SignatureExpired();
        if (newDeadline <= block.timestamp) revert Errors.BadDeadline();
        if (newAmount == 0) revert Errors.BadAmount();
        if (newDescriptionHash == bytes32(0)) revert Errors.BadDescription();
        if (signers.length != 2 || signatures.length != 2) revert Errors.BadSignatures();
        if (signers[0] != founder || signers[1] != investor) revert Errors.BadSigners();

        Milestone storage milestone = _milestones[milestoneIndex];
        if (!Helpers.isRenegotiable(milestone.state)) revert Errors.NotRenegotiable();
        if (block.timestamp > _graceEnds(milestoneIndex, milestone)) revert Errors.GraceExpired();

        RenegotiationTerms memory terms = RenegotiationTerms({
            milestoneIndex: milestoneIndex,
            newDeadline: newDeadline,
            newAmount: newAmount,
            newDescriptionHash: newDescriptionHash
        });

        _verifyRenegotiation(founder, signatures[0], terms);
        _verifyRenegotiation(investor, signatures[1], terms);

        uint256 oldAmount = milestone.amount;
        milestone.amount = newAmount;
        milestone.deadline = newDeadline;
        milestone.descriptionHash = newDescriptionHash;
        milestone.state =
            oldAmount >= newAmount ? uint8(MilestoneState.Funded) : uint8(MilestoneState.Active);

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
        if (milestone.state != uint8(MilestoneState.Funded) && milestone.state != uint8(MilestoneState.Refundable)) {
            revert Errors.NotRefundable();
        }
        if (block.timestamp <= _graceEnds(milestoneIndex)) revert Errors.GraceActive();

        milestone.state = uint8(MilestoneState.Refundable);
        uint256 refundAmount = milestone.amount;
        milestone.state = uint8(MilestoneState.Refunded);

        IERC20(token).safeTransfer(investor, refundAmount);

        emit MilestoneRefunded(milestoneIndex, investor, refundAmount);
        _advanceAfterRefund();
    }

    function createDispute(uint256 milestoneIndex, bytes32 evidenceHash)
        external
        override
        onlyInitialized
        onlyActiveEscrow
    {
        if (msg.sender != founder && msg.sender != investor) revert Errors.Unauthorized();
        if (evidenceHash == bytes32(0)) revert Errors.EmptyEvidence();
        if (milestoneIndex != currentMilestoneIndex) revert Errors.NotCurrentMilestone();
        if (_disputes[milestoneIndex].openedAt != 0) revert Errors.DisputeActive();

        Milestone storage milestone = _milestones[milestoneIndex];
        if (milestone.state != uint8(MilestoneState.Active) && milestone.state != uint8(MilestoneState.Funded)) {
            revert Errors.BadMilestoneState();
        }
        uint64 graceEndsAt = _graceEnds(milestoneIndex);
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

    function resolveExpiredDispute(uint256 milestoneIndex) external override onlyInitialized {
        DisputeInfo memory dispute = _disputes[milestoneIndex];
        if (dispute.openedAt == 0) revert Errors.NoDispute();
        if (block.timestamp <= dispute.endsAt) revert Errors.DisputeActive();

        delete _disputes[milestoneIndex];

        Milestone storage milestone = _milestones[milestoneIndex];
        milestone.state = uint8(MilestoneState.Refundable);

        emit DisputeExpired(milestoneIndex, dispute.priorState);
    }
    

    //okay
    function getMilestone(uint256 milestoneIndex) external view override returns (Milestone memory milestone) {
        if (milestoneIndex >= _milestones.length) revert Errors.BadMilestone();
        return _milestones[milestoneIndex];
    }
    

    // okay
    function getDisputeInfo(uint256 milestoneIndex) external view override returns (DisputeInfo memory info) {
        if (milestoneIndex >= _milestones.length) revert Errors.BadMilestone();
        return _disputes[milestoneIndex];
    }
    
    // okay
    function _releaseMilestone(uint256 milestoneIndex) private {
        Milestone storage milestone = _milestones[milestoneIndex];
        uint256 amount = milestone.amount;

        uint256 feeAmount = Helpers.calculateFee(amount, feeBps);
        uint256 founderAmount = amount - feeAmount;

        milestone.state = uint8(MilestoneState.Released);

        if (founderAmount > 0) IERC20(token).safeTransfer(founder, founderAmount);
        if (feeAmount > 0) {
            IERC20(token).safeTransfer(factory, feeAmount);
            emit FeeCollected(milestoneIndex, factory, feeAmount);
        }

        emit MilestoneReleased(milestoneIndex, founder, founderAmount, feeAmount);
        _advanceAfterRelease();
    }
    
    // okay
    function _advanceAfterRelease() private {
        if (currentMilestoneIndex + 1 == _milestones.length) {
            escrowState = EscrowState.Finalized;
        } else {
            currentMilestoneIndex++;
            _milestones[currentMilestoneIndex].state = uint8(MilestoneState.Active);
        }
    }

    function _advanceAfterRefund() private {
        if (currentMilestoneIndex + 1 == _milestones.length) {
            escrowState = EscrowState.Cancelled;
            emit EscrowCancelled(uint64(block.timestamp));
        } else {
            currentMilestoneIndex++;
            _milestones[currentMilestoneIndex].state = uint8(MilestoneState.Active);
        }
    }
    
    // okay
    function _verifyAcceptance(address signer, bytes calldata signature, uint256 amount, uint256 deadline) private {
        string memory dataString = bytesToString(
            abi.encode(address(this), founder, investor, amount, deadline, block.chainid, nonces[signer])
        );

        if (_recoverValidSignature(getSignedHash(dataString), signature) != signer) revert Errors.BadSignature();

        nonces[signer]++;
    }
    
    // okay
    function _verifyMilestoneSignature(
        uint256 milestoneIndex,
        bytes calldata signature,
        uint256 deadline
    ) private {
        string memory dataString = bytesToString(
            abi.encode(address(this), milestoneIndex, investor, deadline, block.chainid, nonces[investor])
        );

        if (_recoverValidSignature(getSignedHash(dataString), signature) != investor) revert Errors.BadSignature();

        nonces[investor]++;
    }
    
    //okay
    function _verifyRenegotiation(address signer, bytes calldata signature, RenegotiationTerms memory terms) private {
        string memory dataString = bytesToString(
            abi.encode(
                address(this),
                terms.milestoneIndex,
                terms.newDeadline,
                terms.newAmount,
                terms.newDescriptionHash,
                signer,
                terms.deadline,
                block.chainid,
                nonces[signer]
            )
        );

        if (_recoverValidSignature(getSignedHash(dataString), signature) != signer) revert Errors.BadSignature();

        nonces[signer]++;
    }
    
    //okay
    function _recoverValidSignature(bytes32 signedHash, bytes calldata signature)
        private
        pure
        returns (address signer)
    {
        if (signature.length != 65) revert Errors.BadSignatures();

        (bytes32 r, bytes32 s, uint8 v) = splitSignature(signature);
        if ((v != 27 && v != 28) || uint256(s) > SECP256K1_HALF_ORDER) revert Errors.BadSignature();

        signer = ecrecover(signedHash, v, r, s);
        if (signer == address(0)) revert Errors.BadSignature();
    }

    function _graceEnds(uint256 milestoneIndex) private view returns (uint64) {
        return _milestones[milestoneIndex].deadline + uint64(gracePeriod);
    }
}
