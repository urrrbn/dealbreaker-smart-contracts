// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {StringConversions} from "../../src/lib/StringConversions.sol";

contract StringConversionsHarness is StringConversions {
    function uint2strExt(uint256 i) external pure returns (string memory) {
        return uint2str(i);
    }
}

contract StringConversionsTest is Test {
    StringConversionsHarness internal h;

    function setUp() public {
        h = new StringConversionsHarness();
    }

    // ------- uint2str -------

    function testUint2strKnownValues() public view {
        assertEq(h.uint2strExt(0), "0");
        assertEq(h.uint2strExt(7), "7");
        assertEq(h.uint2strExt(10), "10");
        assertEq(h.uint2strExt(12345), "12345");
        assertEq(h.uint2strExt(type(uint256).max), vm.toString(type(uint256).max));
    }

    /// @dev Matches Foundry's reference decimal stringification for any input.
    function testFuzzUint2strMatchesReference(uint256 x) public view {
        assertEq(h.uint2strExt(x), vm.toString(x));
    }

    // ------- bytesToString -------

    /// @dev The string view preserves length and byte content exactly.
    function testFuzzBytesToStringRoundTrips(bytes memory data) public view {
        string memory s = h.bytesToString(data);
        assertEq(bytes(s).length, data.length);
        assertEq(keccak256(bytes(s)), keccak256(data));
    }

    function testBytesToStringEmpty() public view {
        assertEq(bytes(h.bytesToString("")).length, 0);
    }

    function testBytesToStringExact32Bytes() public view {
        bytes memory data = abi.encode(uint256(0xABCDEF));
        string memory s = h.bytesToString(data);
        assertEq(bytes(s).length, 32);
        assertEq(keccak256(bytes(s)), keccak256(data));
    }
}
