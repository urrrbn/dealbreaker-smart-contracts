// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Escrow} from "../src/Escrow.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {Errors} from "../src/lib/Errors.sol";
import {MockERC20} from "./utils/MockERC20.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract EscrowFactoryTest is Test {
    EscrowFactory private factory;
    Escrow private implementation;
    MockERC20 private token;

    address private arbitrator = address(0xA11CE);
    address private founder = address(0xF0A);
    address private investor = address(0xB0B);
    address private outsider = address(0xBAD);

    uint16 private constant FEE = 250;
    uint32 private constant GRACE = 3 days;

    event DefaultFeeRateSet(uint16 defaultFeeRate);
    event DefaultGracePeriodSet(uint32 defaultGracePeriod);
    event DefaultArbitratorSet(address indexed defaultArbitrator);
    event EscrowImplementationChanged(address indexed newImplementation);
    event EscrowStatusChanged(address indexed escrowAddress, bool status);
    event AllowedTokenSet(address indexed token, bool allowed);
    event EscrowDeployed(address indexed escrow);

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        implementation = new Escrow();
        factory = new EscrowFactory();
        factory.initialize(FEE, GRACE, arbitrator, address(implementation));
    }

    // =================================================================
    // initialize
    // =================================================================

    function testInitializeRevertsZeroImplementation() public {
        EscrowFactory f = new EscrowFactory();
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "escrowImplementation"));
        f.initialize(FEE, GRACE, arbitrator, address(0));
    }

    function testInitializeRevertsZeroArbitrator() public {
        EscrowFactory f = new EscrowFactory();
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "defaultArbitrator"));
        f.initialize(FEE, GRACE, address(0), address(implementation));
    }

    function testInitializeRevertsFeeTooHigh() public {
        EscrowFactory f = new EscrowFactory();
        vm.expectRevert(Errors.DefaultFeeRateError.selector);
        f.initialize(1001, GRACE, arbitrator, address(implementation));
    }

    function testInitializeRevertsGraceTooLong() public {
        EscrowFactory f = new EscrowFactory();
        vm.expectRevert(Errors.DefaultGracePeriodError.selector);
        f.initialize(FEE, 30 days + 1, arbitrator, address(implementation));
    }

    function testInitializeSuccess() public {
        EscrowFactory f = new EscrowFactory();
        f.initialize(FEE, GRACE, arbitrator, address(implementation));
        assertEq(f.defaultFeeRate(), FEE);
        assertEq(f.defaultGracePeriod(), GRACE);
        assertEq(f.defaultArbitrator(), arbitrator);
        assertTrue(f.hasRole(f.DEFAULT_ADMIN_ROLE(), address(this)));
        // Beacon deployed and owned by the factory.
        assertTrue(f.getBeaconProxyAddress() != address(0));
        assertEq(f.getEscrowImplementationAddress(), address(implementation));
    }

    function testInitializeRevertsWhenAlreadyInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(FEE, GRACE, arbitrator, address(implementation));
    }

    // =================================================================
    // admin setters - access control
    // =================================================================

    function _expectUnauthorized() internal {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, bytes32(0))
        );
    }

    function testSettersRevertForNonAdmin() public {
        vm.startPrank(outsider);

        _expectUnauthorized();
        factory.setDefaultFeeRate(100);

        _expectUnauthorized();
        factory.setDefaultGracePeriod(1 days);

        _expectUnauthorized();
        factory.setDefaultArbitrator(arbitrator);

        _expectUnauthorized();
        factory.setEscrowImplementation(address(implementation));

        _expectUnauthorized();
        factory.setEscrowStatus(address(0x1234), true);

        _expectUnauthorized();
        factory.setAllowedToken(address(token), true);

        vm.stopPrank();
    }

    // =================================================================
    // setDefaultFeeRate
    // =================================================================

    function testSetDefaultFeeRateRevertsTooHigh() public {
        vm.expectRevert(Errors.DefaultFeeRateError.selector);
        factory.setDefaultFeeRate(1001);
    }

    function testSetDefaultFeeRateSuccess() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit DefaultFeeRateSet(500);
        factory.setDefaultFeeRate(500);
        assertEq(factory.defaultFeeRate(), 500);
    }

    function testSetDefaultFeeRateBoundary() public {
        factory.setDefaultFeeRate(1000);
        assertEq(factory.defaultFeeRate(), 1000);
    }

    // =================================================================
    // setDefaultGracePeriod
    // =================================================================

    function testSetDefaultGracePeriodRevertsTooLong() public {
        vm.expectRevert(Errors.DefaultGracePeriodError.selector);
        factory.setDefaultGracePeriod(30 days + 1);
    }

    function testSetDefaultGracePeriodSuccess() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit DefaultGracePeriodSet(10 days);
        factory.setDefaultGracePeriod(10 days);
        assertEq(factory.defaultGracePeriod(), 10 days);
    }

    // =================================================================
    // setDefaultArbitrator
    // =================================================================

    function testSetDefaultArbitratorRevertsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "defaultArbitrator"));
        factory.setDefaultArbitrator(address(0));
    }

    function testSetDefaultArbitratorSuccess() public {
        address newArb = address(0xDEAD);
        vm.expectEmit(true, false, false, false, address(factory));
        emit DefaultArbitratorSet(newArb);
        factory.setDefaultArbitrator(newArb);
        assertEq(factory.defaultArbitrator(), newArb);
    }

    // =================================================================
    // setEscrowImplementation
    // =================================================================

    function testSetEscrowImplementationRevertsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "newImplementation_"));
        factory.setEscrowImplementation(address(0));
    }

    function testSetEscrowImplementationSuccess() public {
        Escrow newImpl = new Escrow();
        vm.expectEmit(true, false, false, false, address(factory));
        emit EscrowImplementationChanged(address(newImpl));
        factory.setEscrowImplementation(address(newImpl));
        assertEq(factory.getEscrowImplementationAddress(), address(newImpl));
    }

    // =================================================================
    // setEscrowStatus
    // =================================================================

    function testSetEscrowStatusRevertsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "escrowAddress_"));
        factory.setEscrowStatus(address(0), true);
    }

    function testSetEscrowStatusSuccess() public {
        address e = address(0xE5C0);
        vm.expectEmit(true, false, false, true, address(factory));
        emit EscrowStatusChanged(e, true);
        factory.setEscrowStatus(e, true);
        assertTrue(factory.isEscrowActive(e));

        factory.setEscrowStatus(e, false);
        assertFalse(factory.isEscrowActive(e));
    }

    // =================================================================
    // setAllowedToken
    // =================================================================

    function testSetAllowedTokenRevertsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "token_"));
        factory.setAllowedToken(address(0), true);
    }

    function testSetAllowedTokenSuccess() public {
        vm.expectEmit(true, false, false, true, address(factory));
        emit AllowedTokenSet(address(token), true);
        factory.setAllowedToken(address(token), true);
        assertTrue(factory.allowedTokens(address(token)));
    }

    // =================================================================
    // deployEscrow
    // =================================================================

    function _params() internal view returns (IEscrow.InitParams memory params) {
        params.founder = founder;
        params.investor = investor;
        params.token = address(token);
        params.totalAmount = 100 ether;
        params.milestoneAmounts = new uint256[](2);
        params.milestoneAmounts[0] = 40 ether;
        params.milestoneAmounts[1] = 60 ether;
        params.milestoneDeadlines = new uint64[](2);
        params.milestoneDeadlines[0] = uint64(block.timestamp + 10 days);
        params.milestoneDeadlines[1] = uint64(block.timestamp + 20 days);
        params.milestoneDescriptionHashes = new bytes32[](2);
        params.milestoneDescriptionHashes[0] = keccak256("m1");
        params.milestoneDescriptionHashes[1] = keccak256("m2");
    }

    function testDeployRevertsZeroFounder() public {
        IEscrow.InitParams memory p = _params();
        p.founder = address(0);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "params.founder"));
        factory.deployEscrow(p);
    }

    function testDeployRevertsZeroToken() public {
        IEscrow.InitParams memory p = _params();
        p.token = address(0);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "params.token"));
        factory.deployEscrow(p);
    }

    function testDeployRevertsZeroInvestor() public {
        IEscrow.InitParams memory p = _params();
        p.investor = address(0);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "params.investor"));
        factory.deployEscrow(p);
    }

    function testDeployRevertsZeroTotalAmount() public {
        IEscrow.InitParams memory p = _params();
        p.totalAmount = 0;
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmount.selector, "params.totalAmount"));
        factory.deployEscrow(p);
    }

    function testDeployRevertsEmptyMilestones() public {
        IEscrow.InitParams memory p = _params();
        p.milestoneAmounts = new uint256[](0);
        p.milestoneDeadlines = new uint64[](0);
        p.milestoneDescriptionHashes = new bytes32[](0);
        vm.expectRevert(Errors.MilestoneConfigError.selector);
        factory.deployEscrow(p);
    }

    function testDeployRevertsLengthMismatch() public {
        IEscrow.InitParams memory p = _params();
        p.milestoneDeadlines = new uint64[](1);
        p.milestoneDeadlines[0] = uint64(block.timestamp + 10 days);
        vm.expectRevert(Errors.MilestoneConfigError.selector);
        factory.deployEscrow(p);
    }

    function testDeployRevertsZeroMilestoneAmount() public {
        IEscrow.InitParams memory p = _params();
        p.milestoneAmounts[0] = 0;
        p.milestoneAmounts[1] = 100 ether;
        vm.expectRevert(Errors.MilestoneConfigError.selector);
        factory.deployEscrow(p);
    }

    function testDeployRevertsPastDeadline() public {
        vm.warp(1000);
        IEscrow.InitParams memory p = _params();
        p.milestoneDeadlines[0] = uint64(block.timestamp); // <= now
        vm.expectRevert(Errors.MilestoneConfigError.selector);
        factory.deployEscrow(p);
    }

    function testDeployRevertsSumMismatch() public {
        IEscrow.InitParams memory p = _params();
        p.totalAmount = 101 ether; // != 40 + 60
        vm.expectRevert(Errors.MilestoneConfigError.selector);
        factory.deployEscrow(p);
    }

    function testDeployRevertsTokenNotAllowed() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenNotAllowed.selector, address(token)));
        factory.deployEscrow(_params());
    }

    function testDeploySuccess() public {
        factory.setAllowedToken(address(token), true);

        IEscrow.InitParams memory p = _params();
        address escrowAddress = factory.deployEscrow(p);
        Escrow escrow = Escrow(escrowAddress);

        assertTrue(factory.activeEscrows(escrowAddress));
        assertTrue(factory.isEscrowActive(escrowAddress));
        assertEq(escrow.factory(), address(factory));
        assertEq(escrow.founder(), founder);
        assertEq(escrow.investor(), investor);
        assertEq(escrow.token(), address(token));
        assertEq(escrow.feeBps(), FEE);
        assertEq(escrow.gracePeriod(), GRACE);
        assertEq(escrow.arbitrator(), arbitrator);
        assertEq(escrow.getEscrowSummary().totalAmount, 100 ether);
    }

    function testDeployIsPermissionless() public {
        factory.setAllowedToken(address(token), true);
        vm.prank(outsider); // not admin
        address escrowAddress = factory.deployEscrow(_params());
        assertTrue(factory.isEscrowActive(escrowAddress));
    }

    /// @dev Revoking a token after deployment does not disable already-deployed escrows
    ///      (conscious non-invariant from invariants.md).
    function testRevokingTokenDoesNotAffectExistingEscrows() public {
        factory.setAllowedToken(address(token), true);
        address escrowAddress = factory.deployEscrow(_params());
        factory.setAllowedToken(address(token), false);
        assertTrue(factory.isEscrowActive(escrowAddress));
    }
}

