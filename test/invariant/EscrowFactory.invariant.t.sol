// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Escrow} from "../../src/Escrow.sol";
import {EscrowFactory} from "../../src/EscrowFactory.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {EscrowFactoryHandler} from "./handlers/EscrowFactoryHandler.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract EscrowFactoryInvariantTest is Test {
    EscrowFactory internal factory;
    Escrow internal implementation;
    MockERC20 internal token;
    EscrowFactoryHandler internal handler;

    address internal arbitrator = address(0xA11CE);

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        implementation = new Escrow();
        factory = new EscrowFactory();
        factory.initialize(250, 3 days, arbitrator, address(implementation));

        handler = new EscrowFactoryHandler(factory, token);
        // The handler must be admin to exercise the setters.
        factory.grantRole(factory.DEFAULT_ADMIN_ROLE(), address(handler));

        targetContract(address(handler));
    }

    // ------- config bounds -------

    function invariant_feeRateBounded() public view {
        assertLe(factory.defaultFeeRate(), 1000);
    }

    function invariant_gracePeriodBounded() public view {
        assertLe(factory.defaultGracePeriod(), 30 days);
    }

    function invariant_arbitratorNeverZero() public view {
        assertTrue(factory.defaultArbitrator() != address(0));
    }

    // ------- beacon -------

    function invariant_beaconSetAndOwnedByFactory() public view {
        address beacon = factory.getBeaconProxyAddress();
        assertTrue(beacon != address(0));
        assertEq(UpgradeableBeacon(beacon).owner(), address(factory));
    }

    // ------- deployment -------
    function invariant_deployedEscrowsStartActive() public view {
        uint256 n = handler.deployedCount();
        for (uint256 i = 0; i < n; i++) {
            address e = handler.deployed(i);
            // Only assert for escrows whose status has not been explicitly changed since deployment.
            if (handler.ghost_expectedActive(e)) {
                assertTrue(factory.isEscrowActive(e));
            }
        }
    }

    function afterInvariant() public view {
        console2.log("feeRatesSet           ", handler.feeRatesSet());
        console2.log("gracePeriodsSet       ", handler.gracePeriodsSet());
        console2.log("arbitratorsSet        ", handler.arbitratorsSet());
        console2.log("zeroArbitratorAttempts", handler.zeroArbitratorAttempts());
        console2.log("deploys               ", handler.deploys());
    }
}
