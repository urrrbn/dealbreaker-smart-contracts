// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {EscrowFactory} from "../../../src/EscrowFactory.sol";
import {IEscrow} from "../../../src/interfaces/IEscrow.sol";
import {MockERC20} from "../../utils/MockERC20.sol";

contract EscrowFactoryHandler is CommonBase, StdCheats, StdUtils {
    EscrowFactory public factory;
    MockERC20 public token;

    address[] public deployed;

    mapping(address => bool) public ghost_expectedActive;
    address[] public touched;
    mapping(address => bool) internal seen;

    uint256 public feeRatesSet;
    uint256 public gracePeriodsSet;
    uint256 public arbitratorsSet;
    uint256 public zeroArbitratorAttempts;
    uint256 public deploys;

    constructor(EscrowFactory factory_, MockERC20 token_) {
        factory = factory_;
        token = token_;
    }

    function deployedCount() external view returns (uint256) {
        return deployed.length;
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    function _recordStatus(address a, bool status) internal {
        if (!seen[a]) {
            seen[a] = true;
            touched.push(a);
        }
        ghost_expectedActive[a] = status;
    }

    function setFeeRate(uint16 rate) external {
        try factory.setDefaultFeeRate(rate) {
            feeRatesSet++;
        } catch {}
    }

    function setGracePeriod(uint32 grace) external {
        try factory.setDefaultGracePeriod(grace) {
            gracePeriodsSet++;
        } catch {}
    }

    function setArbitrator(address arb) external {
        try factory.setDefaultArbitrator(arb) {
            arbitratorsSet++;
        } catch {}
    }

    function setArbitratorZero() external {
        zeroArbitratorAttempts++;
        try factory.setDefaultArbitrator(address(0)) {
            arbitratorsSet++;
        } catch {}
    }

    function setAllowedToken(address t, bool allowed) external {
        try factory.setAllowedToken(t, allowed) {} catch {}
    }

    function setEscrowStatus(address e, bool status) external {
        try factory.setEscrowStatus(e, status) {
            _recordStatus(e, status);
        } catch {}
    }

    function deployEscrow(uint256 amount, uint256 deadlineDelta, address founder, address investor) external {
        if (founder == address(0) || investor == address(0)) return;
        amount = bound(amount, 2, 1_000_000 ether);
        uint64 dl = uint64(block.timestamp + bound(deadlineDelta, 1 days, 60 days));

        // Always (re)allow our token so a valid deploy is reachable regardless of prior fuzzing.
        factory.setAllowedToken(address(token), true);

        IEscrow.InitParams memory p;
        p.founder = founder;
        p.investor = investor;
        p.token = address(token);
        p.totalAmount = amount;
        p.milestoneAmounts = new uint256[](2);
        p.milestoneAmounts[0] = amount / 2;
        p.milestoneAmounts[1] = amount - amount / 2;
        p.milestoneDeadlines = new uint64[](2);
        p.milestoneDeadlines[0] = dl;
        p.milestoneDeadlines[1] = dl + 1 days;
        p.milestoneDescriptionHashes = new bytes32[](2);
        p.milestoneDescriptionHashes[0] = keccak256("a");
        p.milestoneDescriptionHashes[1] = keccak256("b");

        try factory.deployEscrow(p) returns (address e) {
            deployed.push(e);
            deploys++;
            _recordStatus(e, true);
        } catch {}
    }
}
