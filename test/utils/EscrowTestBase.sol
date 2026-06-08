// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Escrow} from "../../src/Escrow.sol";
import {EscrowFactory} from "../../src/EscrowFactory.sol";
import {IEscrow} from "../../src/interfaces/IEscrow.sol";
import {Errors} from "../../src/lib/Errors.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Shared scaffolding: factory + beacon-proxy escrow setup, a mock token, and EIP-191
///      `personal_sign` signature helpers that mirror the contract's own encoding by reusing its
///      public `bytesToString` / `getSignedHash` pure functions.
abstract contract EscrowTestBase is Test {
    EscrowFactory internal factory;
    Escrow internal implementation;
    MockERC20 internal token;

    // Signers (private keys drive deterministic addresses).
    uint256 internal founderPk = 0xF00D;
    uint256 internal investorPk = 0xB0B;
    uint256 internal arbitratorPk = 0xA11CE;
    uint256 internal strangerPk = 0xBEEF;

    address internal founder;
    address internal investor;
    address internal arbitrator;
    address internal stranger;

    uint16 internal constant FEE_BPS = 250; // 2.5%
    uint32 internal constant GRACE = 3 days;

    uint256 internal constant M0 = 40 ether;
    uint256 internal constant M1 = 60 ether;
    uint256 internal constant TOTAL = M0 + M1;

    function setUp() public virtual {
        founder = vm.addr(founderPk);
        investor = vm.addr(investorPk);
        arbitrator = vm.addr(arbitratorPk);
        stranger = vm.addr(strangerPk);

        token = new MockERC20("USD Coin", "USDC", 6);
        implementation = new Escrow();
        factory = new EscrowFactory();
        factory.initialize(FEE_BPS, GRACE, arbitrator, address(implementation));
        factory.setAllowedToken(address(token), true);

        token.mint(investor, 1_000_000 ether);
        token.mint(stranger, 1_000_000 ether);
    }

    // -----------------------------------------------------------------
    // Param builders
    // -----------------------------------------------------------------

    function _defaultParams() internal view returns (IEscrow.InitParams memory params) {
        params.founder = founder;
        params.investor = investor;
        params.token = address(token);
        params.totalAmount = TOTAL;
        params.milestoneAmounts = new uint256[](2);
        params.milestoneAmounts[0] = M0;
        params.milestoneAmounts[1] = M1;
        params.milestoneDeadlines = new uint64[](2);
        params.milestoneDeadlines[0] = uint64(block.timestamp + 10 days);
        params.milestoneDeadlines[1] = uint64(block.timestamp + 20 days);
        params.milestoneDescriptionHashes = new bytes32[](2);
        params.milestoneDescriptionHashes[0] = keccak256("milestone 1");
        params.milestoneDescriptionHashes[1] = keccak256("milestone 2");
    }

    function _singleMilestoneParams() internal view returns (IEscrow.InitParams memory params) {
        params.founder = founder;
        params.investor = investor;
        params.token = address(token);
        params.totalAmount = M0;
        params.milestoneAmounts = new uint256[](1);
        params.milestoneAmounts[0] = M0;
        params.milestoneDeadlines = new uint64[](1);
        params.milestoneDeadlines[0] = uint64(block.timestamp + 10 days);
        params.milestoneDescriptionHashes = new bytes32[](1);
        params.milestoneDescriptionHashes[0] = keccak256("only milestone");
    }

    // -----------------------------------------------------------------
    // Deployment / lifecycle helpers
    // -----------------------------------------------------------------

    function _deploy(IEscrow.InitParams memory params) internal returns (Escrow) {
        return Escrow(factory.deployEscrow(params));
    }

    function _deployDefault() internal returns (Escrow) {
        return _deploy(_defaultParams());
    }

    function _activate(Escrow escrow) internal {
        uint256 deadline = block.timestamp + 1 days;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signAcceptance(escrow, founderPk, deadline);
        sigs[1] = _signAcceptance(escrow, investorPk, deadline);
        escrow.activateEscrow(sigs, deadline);
    }

    /// @dev Deploys + activates a default escrow with the current milestone funded.
    function _activeFunded() internal returns (Escrow escrow) {
        escrow = _deployDefault();
        _activate(escrow);
        _deposit(escrow, 0, investor);
    }

    function _deposit(Escrow escrow, uint256 index, address from) internal {
        uint256 amount = escrow.getMilestone(index).amount;
        vm.startPrank(from);
        token.approve(address(escrow), amount);
        escrow.deposit(index);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Signature helpers (mirror Escrow's encoding)
    // -----------------------------------------------------------------

    function _sign(Escrow escrow, uint256 pk, bytes memory encoded) internal pure returns (bytes memory) {
        bytes32 digest = escrow.getSignedHash(escrow.bytesToString(encoded));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signAcceptance(Escrow escrow, uint256 pk, uint256 deadline) internal view returns (bytes memory) {
        address signer = vm.addr(pk);
        bytes memory encoded = abi.encode(
            address(escrow), escrow.founder(), escrow.investor(), deadline, block.chainid, escrow.nonces(signer)
        );
        return _sign(escrow, pk, encoded);
    }

    function _signVerify(Escrow escrow, uint256 index, uint256 deadline) internal view returns (bytes memory) {
        bytes memory encoded = abi.encode(
            address(escrow), index, escrow.investor(), deadline, block.chainid, escrow.nonces(escrow.investor())
        );
        return _sign(escrow, investorPk, encoded);
    }

    /// @dev Holds the renegotiation signing fields in memory so the encoding helper stays under the
    ///      stack limit even when the optimizer/viaIR are disabled (e.g. under `forge coverage`).
    struct RenegSig {
        uint256 index;
        uint64 newDeadline;
        uint256 newAmount;
        bytes32 newDescriptionHash;
        uint256 deadline;
    }

    function _signReneg(
        Escrow escrow,
        uint256 pk,
        uint256 index,
        uint64 newDeadline,
        uint256 newAmount,
        bytes32 newDescriptionHash,
        uint256 deadline
    ) internal view returns (bytes memory) {
        RenegSig memory t;
        t.index = index;
        t.newDeadline = newDeadline;
        t.newAmount = newAmount;
        t.newDescriptionHash = newDescriptionHash;
        t.deadline = deadline;
        return _signReneg(escrow, pk, t);
    }

    function _signReneg(Escrow escrow, uint256 pk, RenegSig memory t) internal view returns (bytes memory) {
        // Encode in two static chunks and concat. All fields are fixed 32-byte types, so this is
        // byte-identical to a single abi.encode while keeping each expression under the stack limit
        // when the optimizer/viaIR are disabled (e.g. under `forge coverage`).
        bytes memory head = abi.encode(address(escrow), t.index, t.newDeadline, t.newAmount, t.newDescriptionHash);
        bytes memory tail = abi.encode(vm.addr(pk), t.deadline, block.chainid, escrow.nonces(vm.addr(pk)));
        return _sign(escrow, pk, bytes.concat(head, tail));
    }
}
