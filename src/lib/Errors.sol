// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Errors {
    /// @notice Error thrown when a zero address is provided where it is not allowed.
    error ZeroAddress(string target);

    /// @notice Error thrown when an empty string is provided where it is not allowed.
    error EmptyString(string target);

    /// @notice Error thrown when a zero amount is provided where it is not allowed.
    error ZeroAmount(string target);

    /// @notice Error thrown when milestone initialization config is invalid.
    error MilestoneConfigError();

    error DefaultFeeRateError();
    error DefaultGracePeriodError();
    error TokenNotAllowed(address token);
    error FailedEscrowDeployment();
    error EscrowNotInitialized();
    error EscrowNotActive();
    error OnlyFactory();
    error FeeTooHigh();
    error BadEscrowState();
    error SignatureExpired();
    error BadSignatures();
    error OnlyInvestor();
    error NotCurrentMilestone();
    error NotDepositable();
    error EmptyEvidence();
    error NotFunded();
    error GraceExpired();
    error BadDeadline();
    error BadAmount();
    error BadDescription();
    error BadSigners();
    error NotRenegotiable();
    error NotRefundable();
    error GraceActive();
    error Unauthorized();
    error DisputeActive();
    error BadMilestoneState();
    error OutsideDisputeWindow();
    error NoDispute();
    error BadMilestone();
    error BadSignature();
    error OnlyArbitrator();
}
