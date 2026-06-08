// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {VerifySignature} from "../../src/lib/VerifySignature.sol";
import {Errors} from "../../src/lib/Errors.sol";

/// @dev Exposes the internal `_recoverValidSignature` as an external entrypoint.
contract VerifySignatureHarness is VerifySignature {
    function recover(bytes32 hash, bytes calldata sig) external pure returns (address) {
        return _recoverValidSignature(hash, sig);
    }
}

contract VerifySignatureTest is Test {
    VerifySignatureHarness internal h;

    uint256 internal signerPk = 0xA11CE;
    address internal signer;

    function setUp() public {
        h = new VerifySignatureHarness();
        signer = vm.addr(signerPk);
    }

    // ------- hashing helpers -------

    function testGetSignedHashLengthPrefix() public view {
        // getSignedHash("abc") = keccak("\x19Ethereum Signed Message:\n3abc")
        bytes32 expected = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n3", "abc"));
        assertEq(h.getSignedHash("abc"), expected);
    }

    function testGetEthSignedHash() public view {
        bytes32 msgHash = keccak256("hello");
        bytes32 expected = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        assertEq(h.getEthSignedHash(msgHash), expected);
    }

    // ------- _recoverValidSignature -------

    function testRecoverValidSignature() public view {
        bytes32 digest = h.getSignedHash("payload");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertEq(h.recover(digest, sig), signer);
    }

    function testRecoverRevertsBadLength() public {
        bytes memory sig = new bytes(64);
        vm.expectRevert(Errors.BadSignatures.selector);
        h.recover(keccak256("x"), sig);
    }

    function testRecoverRevertsBadV() public {
        bytes32 digest = h.getSignedHash("payload");
        (, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, uint8(26)); // invalid v
        vm.expectRevert(Errors.BadSignature.selector);
        h.recover(digest, sig);
    }

    function testRecoverRevertsMalleableHighS() public {
        bytes32 digest = h.getSignedHash("payload");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        // Flip to the malleable counterpart: s' = n - s, v' = flip. Upper-half s must be rejected.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory sig = abi.encodePacked(r, highS, flippedV);
        vm.expectRevert(Errors.BadSignature.selector);
        h.recover(digest, sig);
    }

    function testRecoverWrongSignerMismatch() public view {
        bytes32 digest = h.getSignedHash("payload");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, digest); // different key
        bytes memory sig = abi.encodePacked(r, s, v);
        // Recovers a valid but different address (not `signer`).
        assertTrue(h.recover(digest, sig) != signer);
        assertEq(h.recover(digest, sig), vm.addr(0xBEEF));
    }

    /// @dev Round-trips for any private key / message: a canonical Foundry signature recovers the signer.
    function testFuzzRecoverRoundTrips(uint256 pk, bytes32 raw) public view {
        pk = bound(pk, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        bytes32 digest = h.getEthSignedHash(raw);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertEq(h.recover(digest, sig), vm.addr(pk));
    }
}
