// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Helpers} from "../../src/lib/Helpers.sol";
import {Errors} from "../../src/lib/Errors.sol";
import {IEscrow} from "../../src/interfaces/IEscrow.sol";

contract HelpersHarness {
    function checkZeroAddress(address v, string memory t) external pure {
        Helpers.checkZeroAddress(v, t);
    }

    function checkEmptyString(string memory v, string memory t) external pure {
        Helpers.checkEmptyString(v, t);
    }

    function checkZeroAmount(uint256 v, string memory t) external pure {
        Helpers.checkZeroAmount(v, t);
    }

    function calculateFee(uint256 amount, uint16 feeBps) external pure returns (uint256) {
        return Helpers.calculateFee(amount, feeBps);
    }

    function isRenegotiable(IEscrow.MilestoneState s) external pure returns (bool) {
        return Helpers.isRenegotiable(s);
    }

    function validateMilestones(IEscrow.InitParams calldata p) external view {
        Helpers.validateMilestones(p);
    }
}

contract HelpersTest is Test {
    HelpersHarness internal h;

    function setUp() public {
        h = new HelpersHarness();
    }

    // ------- checkZeroAddress -------

    function testCheckZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "x"));
        h.checkZeroAddress(address(0), "x");
    }

    function testCheckZeroAddressPasses() public view {
        h.checkZeroAddress(address(0x1), "x");
    }

    // ------- checkEmptyString -------

    function testCheckEmptyStringReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.EmptyString.selector, "x"));
        h.checkEmptyString("", "x");
    }

    function testCheckEmptyStringPasses() public view {
        h.checkEmptyString("ok", "x");
    }

    // ------- checkZeroAmount -------

    function testCheckZeroAmountReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmount.selector, "x"));
        h.checkZeroAmount(0, "x");
    }

    // ------- calculateFee -------

    function testCalculateFeeKnownValues() public view {
        assertEq(h.calculateFee(100 ether, 250), 2.5 ether); // 2.5%
        assertEq(h.calculateFee(100 ether, 1000), 10 ether); // 10%
        assertEq(h.calculateFee(100 ether, 0), 0);
    }

    function testCalculateFeeRoundsDown() public view {
        // 1 wei * 250 / 10000 = 0 (rounds down)
        assertEq(h.calculateFee(1, 250), 0);
    }

    /// @dev Fee never exceeds amount/10 for any allowed feeBps (<= 1000), and never exceeds amount.
    function testFuzzCalculateFeeBounded(uint256 amount, uint16 feeBps) public view {
        amount = bound(amount, 0, type(uint128).max);
        feeBps = uint16(bound(feeBps, 0, 1000));
        uint256 fee = h.calculateFee(amount, feeBps);
        assertLe(fee, amount / 10);
        assertLe(fee, amount);
    }

    // ------- isRenegotiable -------

    function testIsRenegotiable() public view {
        assertTrue(h.isRenegotiable(IEscrow.MilestoneState.Active));
        assertTrue(h.isRenegotiable(IEscrow.MilestoneState.Funded));
        assertTrue(h.isRenegotiable(IEscrow.MilestoneState.Refundable));

        assertFalse(h.isRenegotiable(IEscrow.MilestoneState.Pending));
        assertFalse(h.isRenegotiable(IEscrow.MilestoneState.Verified));
        assertFalse(h.isRenegotiable(IEscrow.MilestoneState.Released));
        assertFalse(h.isRenegotiable(IEscrow.MilestoneState.Refunded));
    }

    // ------- validateMilestones -------

    function _params() internal view returns (IEscrow.InitParams memory p) {
        p.founder = address(0xF0A);
        p.investor = address(0xB0B);
        p.token = address(0xC0FFEE);
        p.totalAmount = 100 ether;
        p.milestoneAmounts = new uint256[](2);
        p.milestoneAmounts[0] = 40 ether;
        p.milestoneAmounts[1] = 60 ether;
        p.milestoneDeadlines = new uint64[](2);
        p.milestoneDeadlines[0] = uint64(block.timestamp + 10 days);
        p.milestoneDeadlines[1] = uint64(block.timestamp + 20 days);
        p.milestoneDescriptionHashes = new bytes32[](2);
        p.milestoneDescriptionHashes[0] = keccak256("m1");
        p.milestoneDescriptionHashes[1] = keccak256("m2");
    }

    function testValidateMilestonesPasses() public view {
        h.validateMilestones(_params());
    }

    function testValidateMilestonesRevertsEmpty() public {
        IEscrow.InitParams memory p = _params();
        p.milestoneAmounts = new uint256[](0);
        p.milestoneDeadlines = new uint64[](0);
        p.milestoneDescriptionHashes = new bytes32[](0);
        vm.expectRevert(Errors.MilestoneConfigError.selector);
        h.validateMilestones(p);
    }

    function testValidateMilestonesRevertsAmountLenMismatch() public {
        IEscrow.InitParams memory p = _params();
        p.milestoneDeadlines = new uint64[](1);
        vm.expectRevert(Errors.MilestoneConfigError.selector);
        h.validateMilestones(p);
    }

    function testValidateMilestonesRevertsDescLenMismatch() public {
        IEscrow.InitParams memory p = _params();
        p.milestoneDescriptionHashes = new bytes32[](1);
        vm.expectRevert(Errors.MilestoneConfigError.selector);
        h.validateMilestones(p);
    }

    function testValidateMilestonesRevertsZeroAmount() public {
        IEscrow.InitParams memory p = _params();
        p.milestoneAmounts[0] = 0;
        vm.expectRevert(Errors.MilestoneConfigError.selector);
        h.validateMilestones(p);
    }

    function testValidateMilestonesRevertsPastDeadline() public {
        vm.warp(1000);
        IEscrow.InitParams memory p = _params();
        p.milestoneDeadlines[0] = uint64(block.timestamp); // <= now
        vm.expectRevert(Errors.MilestoneConfigError.selector);
        h.validateMilestones(p);
    }

    function testValidateMilestonesRevertsSumMismatch() public {
        IEscrow.InitParams memory p = _params();
        p.totalAmount = 99 ether;
        vm.expectRevert(Errors.MilestoneConfigError.selector);
        h.validateMilestones(p);
    }
}
