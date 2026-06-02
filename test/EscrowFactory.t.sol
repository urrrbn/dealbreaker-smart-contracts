// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Escrow} from "../src/Escrow.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {Errors} from "../src/lib/Errors.sol";

contract EscrowFactoryTest is Test {
    EscrowFactory private factory;
    Escrow private implementation;

    address private arbitrator = address(0xA11CE);
    address private founder = address(0xF0A);
    address private investor = address(0xB0B);
    address private token = address(0xC0FFEE);

    function setUp() public {
        implementation = new Escrow();
        factory = new EscrowFactory();
        factory.initialize(250, 3 days, arbitrator, address(implementation));
    }

    function testDeployEscrowInitializesProxy() public {
        factory.setAllowedToken(token, true);

        IEscrow.InitParams memory params = _defaultParams();
        address escrowAddress = factory.deployEscrow(params);
        Escrow escrow = Escrow(escrowAddress);

        assertTrue(factory.activeEscrows(escrowAddress));
        assertEq(escrow.factory(), address(factory));
        assertEq(escrow.founder(), founder);
        assertEq(escrow.investor(), investor);
        assertEq(escrow.token(), token);
        assertEq(escrow.getEscrowSummary().totalAmount, 100 ether);
        assertEq(escrow.feeBps(), 250);
        assertEq(escrow.gracePeriod(), 3 days);
        assertEq(escrow.arbitrator(), arbitrator);
    }

    function testDeployEscrowRevertsForDisallowedToken() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenNotAllowed.selector, token));

        factory.deployEscrow(_defaultParams());
    }

    function _defaultParams() private view returns (IEscrow.InitParams memory params) {
        params.founder = founder;
        params.investor = investor;
        params.token = token;
        params.totalAmount = 100 ether;
        params.milestoneAmounts = new uint256[](2);
        params.milestoneAmounts[0] = 40 ether;
        params.milestoneAmounts[1] = 60 ether;
        params.milestoneDeadlines = new uint64[](2);
        params.milestoneDeadlines[0] = uint64(block.timestamp + 10 days);
        params.milestoneDeadlines[1] = uint64(block.timestamp + 20 days);
        params.milestoneDescriptionHashes = new bytes32[](2);
        params.milestoneDescriptionHashes[0] = keccak256("milestone 1");
        params.milestoneDescriptionHashes[1] = keccak256("milestone 2");
    }
}
