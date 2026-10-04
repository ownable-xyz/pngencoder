// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PNGEncoder.sol";

/// Differential fuzz test for the lane-arithmetic Adler-32. The reference is
/// the plain recurrence that processes one byte at a time. The Adler function
/// of the encoder is private. Thus the test calls it through the windowed API.
/// The `newAdler` return value of that API is the running Adler state for the
/// scanlines of the band.
contract AdlerTest is Test {
    PNGEncoder internal enc;

    function setUp() public {
        enc = new PNGEncoder();
    }

    /// The reference recurrence for each byte, with the same deferred modulo.
    function _refAdler(uint32 state, bytes memory data) internal pure returns (uint32) {
        uint256 s1 = state & 0xFFFF;
        uint256 s2 = state >> 16;
        for (uint256 i = 0; i < data.length; i++) {
            s1 += uint8(data[i]);
            s2 += s1;
        }
        s1 %= 65521;
        s2 %= 65521;
        return uint32((s2 << 16) | s1);
    }

    /// Fuzz test. The scanlines of an indexed band of width 1 are `[00 b] [00
    /// b] ...`: one filter byte before each source byte. Thus the test
    /// calculates the expected Adler value directly from the fuzz input. Then
    /// it compares that value with the result of pngStreamBand.
    function testFuzz_Adler_MatchesReference(bytes memory data, uint32 seed) public view {
        vm.assume(data.length > 0 && data.length <= 2048);
        uint32 state = uint32(bound(seed, 1, 0xFFFE) | (bound(uint256(seed) >> 16, 0, 0xFFFE) << 16));

        // The scanlines that the encoder makes: filter byte 0 before each row
        // byte.
        bytes memory scanlines = new bytes(data.length * 2);
        for (uint256 i = 0; i < data.length; i++) {
            scanlines[2 * i] = 0x00;
            scanlines[2 * i + 1] = data[i];
        }

        (, uint32 got) = enc.pngStreamBand(data, 1, 1, true, state);
        assertEq(got, _refAdler(state, scanlines), "adler divergence");
    }
}
