// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEscrow} from "../interfaces/IEscrow.sol";
import {Errors} from "../lib/Errors.sol";

/// @title Helpers
/// @dev Stateless validation helpers.
library Helpers {
    uint16 internal constant BASIS_POINTS_DENOMINATOR = 10_000;

    /// @dev Internal function to check for zero addresses and revert if necessary.
    function checkZeroAddress(address variable_, string memory target_) internal pure {
        if (variable_ == address(0)) revert Errors.ZeroAddress({target: target_});
    }

    /// @dev Internal function to check for empty strings and revert if necessary.
    function checkEmptyString(string memory variable_, string memory target_) internal pure {
        if (bytes(variable_).length == 0) revert Errors.EmptyString({target: target_});
    }

    /// @dev Internal function to check for zero amounts and revert if necessary.
    function checkZeroAmount(uint256 variable_, string memory target_) internal pure {
        if (variable_ == 0) revert Errors.ZeroAmount({target: target_});
    }

    /// @dev Calculates a basis-points fee.
    function calculateFee(uint256 amount, uint16 feeBps) internal pure returns (uint256) {
        return amount * feeBps / BASIS_POINTS_DENOMINATOR;
    }

    /// @dev Returns whether a milestone state can be renegotiated.
    function isRenegotiable(uint8 state) internal pure returns (bool) {
        return state == uint8(IEscrow.MilestoneState.Active) || state == uint8(IEscrow.MilestoneState.Funded)
            || state == uint8(IEscrow.MilestoneState.Refundable);
    }

    /// @dev Internal function to validate milestone initialization parameters.
    function validateMilestones(IEscrow.InitParams calldata params) internal view {
        uint256 milestonesCount = params.milestoneAmounts.length;
        if (
            milestonesCount == 0 || milestonesCount != params.milestoneDeadlines.length
                || milestonesCount != params.milestoneDescriptionHashes.length
        ) {
            revert Errors.MilestoneConfigError();
        }

        uint256 totalAmount;
        for (uint256 i = 0; i < milestonesCount; i++) {
            if (params.milestoneAmounts[i] == 0) revert Errors.MilestoneConfigError();
            if (params.milestoneDeadlines[i] <= block.timestamp) revert Errors.MilestoneConfigError();

            totalAmount += params.milestoneAmounts[i];
        }

        if (totalAmount != params.totalAmount) revert Errors.MilestoneConfigError();
    }
}
