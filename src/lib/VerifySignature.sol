// SPDX-License-Identifier: UNLICENSED

import "./StringConversions.sol";
import {Errors} from "./Errors.sol";

pragma solidity ^0.8.0;

contract VerifySignature is StringConversions {
    uint256 private constant SECP256K1_HALF_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // use this function to get the hash of any string
    function getHash(string memory str) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(str));
    }

    // take the keccak256 hashed message from the getHash function above and input into this function
    // this function prefixes the hash above with \x19Ethereum signed message:\n32 + hash
    // and produces a new hash signature
    function getEthSignedHash(bytes32 _messageHash) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", _messageHash));
    }

    function getSignedHash(string memory _message) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", uint2str(bytes(_message).length), _message));
    }

    function splitSignature(bytes memory sig) public pure returns (bytes32, bytes32, uint8) {
        require(sig.length == 65);

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            // first 32 bytes, after the length prefix
            r := mload(add(sig, 32))
            // second 32 bytes
            s := mload(add(sig, 64))
            // final byte (first byte of the next 32 bytes)
            v := byte(0, mload(add(sig, 96)))
        }

        return (r, s, v);
    }

    /// @dev Recovers the signer from a 65-byte signature, rejecting malformed `v` and the
    ///      malleable upper half of `s` (EIP-2). Reverts if recovery yields the zero address.
    function _recoverValidSignature(bytes32 signedHash, bytes calldata signature)
        internal
        pure
        returns (address signer)
    {
        if (signature.length != 65) revert Errors.BadSignatures();

        (bytes32 r, bytes32 s, uint8 v) = splitSignature(signature);
        if ((v != 27 && v != 28) || uint256(s) > SECP256K1_HALF_ORDER) revert Errors.BadSignature();

        signer = ecrecover(signedHash, v, r, s);
        if (signer == address(0)) revert Errors.BadSignature();
    }
}
