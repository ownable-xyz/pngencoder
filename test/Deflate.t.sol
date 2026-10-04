// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Deflate.sol";
import "./InflateLib.sol";

/// Tests the DEFLATE compressor. An independent decoder inflates the output,
/// and the test makes sure that the result is the same as the input. The inputs
/// include runs, literals, matches at distance N, the full byte range, and
/// fixed and dynamic blocks.
contract DeflateTest is Test {
    function _roundTrip(bytes memory data) internal pure {
        bytes memory back = InflateLib.inflate(Deflate.compress(data));
        require(keccak256(back) == keccak256(data), "round-trip mismatch");
    }

    function test_Empty() public pure {
        _roundTrip("");
    }

    function test_SingleByte() public pure {
        _roundTrip(hex"5a");
    }

    function test_ShortRuns() public pure {
        _roundTrip(hex"41414141"); // "AAAA"
        _roundTrip(hex"4242"); // "BB" (too short for a back-ref)
        _roundTrip("hello world, hello world");
    }

    function test_LongRun() public pure {
        bytes memory a = new bytes(300); // exceeds the 258 max copy length
        for (uint256 i = 0; i < 300; i++) {
            a[i] = 0x00;
        }
        _roundTrip(a);
    }

    function test_MixedRunsAndLiterals() public pure {
        bytes memory b = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            b[i] = bytes1(uint8(i < 20 ? 0xAA : (i < 24 ? i : 0x00)));
        }
        _roundTrip(b);
    }

    function test_AllByteValues() public pure {
        bytes memory b = new bytes(256);
        for (uint256 i = 0; i < 256; i++) {
            b[i] = bytes1(uint8(i)); // exercises 8- and 9-bit literal codes
        }
        _roundTrip(b);
    }

    function test_CompressesFlatRuns() public pure {
        bytes memory a = new bytes(1000);
        // All zeros: the output must be much smaller than the input.
        require(Deflate.compress(a).length < 100, "flat run should compress well");
    }

    function test_RepeatedPattern() public pure {
        // "ABCD" x 100. There are no adjacent repeats, so RLE alone cannot
        // compress this. LZ77 finds the back-references at distance 4.
        bytes memory b = new bytes(400);
        for (uint256 i = 0; i < 400; i++) {
            b[i] = bytes1(uint8(0x41 + (i % 4)));
        }
        _roundTrip(b);
        require(Deflate.compress(b).length < 40, "repeat compresses via distance-N matching");
    }

    function test_DynamicSkewed() public pure {
        // A large, skewed stream with low redundancy. Some bytes occur
        // frequently and some occur rarely. Dynamic Huffman is made for this
        // case. The stream must round-trip with the code book (dynamic or
        // fixed) that the encoder selects.
        bytes memory b = new bytes(3000);
        for (uint256 i = 0; i < 3000; i++) {
            uint256 m = (i * 1103515245 + 12345) % 100;
            b[i] = bytes1(uint8(m < 70 ? 0x65 : (m < 90 ? 0x74 : (m < 97 ? 0x61 : (i % 256)))));
        }
        _roundTrip(b);
    }

    function test_MatchAtDistance32768_RoundTrips() public pure {
        // Regression test: a back-reference at the exact limit of the 32 KB
        // window. The LZ77 token packs the distance in 15 bits (maximum 32767).
        // Thus the window check must reject distance 32768. If the encoder
        // emits this distance, it aliases to distance 0 and corrupts the stream
        // or causes a revert.
        //
        // Construction: a 3-byte marker at offset 0 and at offset 32768, with a
        // constant 0x80 filler between them. The marker hashes to bucket 272,
        // and the filler hashes to bucket 8064. Thus offset 0 is the head of
        // its chain when the encoder matches position 32768. This gives a
        // candidate at a distance of exactly 32768.
        uint256 n = 32768 + 3;
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            b[i] = 0x80;
        }
        b[0] = 0x01;
        b[1] = 0x02;
        b[2] = 0x03;
        b[32768] = 0x01;
        b[32769] = 0x02;
        b[32770] = 0x03;
        _roundTrip(b);
    }

    // ---- run-length (distance-1) path ------------------------------------

    function _roundTripRLE(bytes memory data) internal pure {
        bytes memory back = InflateLib.inflate(Deflate.compressRLE(data));
        require(keccak256(back) == keccak256(data), "RLE round-trip mismatch");
    }

    function test_RLE_RoundTrips() public pure {
        _roundTripRLE("");
        _roundTripRLE(hex"5a");
        _roundTripRLE(hex"41414141"); // "AAAA"
        _roundTripRLE(hex"4242"); // too short for a match
        _roundTripRLE("hello world, hello world");
    }

    function test_RLE_LongRun() public pure {
        bytes memory a = new bytes(600); // multiple 258-length matches
        for (uint256 i = 0; i < 600; i++) {
            a[i] = 0x77;
        }
        _roundTripRLE(a);
    }

    function test_RLE_RunBoundaries() public pure {
        // 259..262 test the logic for "no 1-byte or 2-byte tail after a 258
        // match".
        for (uint256 len = 256; len <= 262; len++) {
            bytes memory a = new bytes(len);
            for (uint256 i = 0; i < len; i++) {
                a[i] = 0x33;
            }
            _roundTripRLE(a);
        }
    }

    function test_RLE_AllByteValues() public pure {
        bytes memory b = new bytes(256);
        for (uint256 i = 0; i < 256; i++) {
            b[i] = bytes1(uint8(i)); // no runs -> all literals, must still round-trip
        }
        _roundTripRLE(b);
    }

    function test_RLE_MixedRunsAndLiterals() public pure {
        bytes memory b = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            b[i] = bytes1(uint8(i < 20 ? 0xAA : (i < 24 ? i : 0x00)));
        }
        _roundTripRLE(b);
    }

    function test_RLE_CompressesFlatRuns() public pure {
        bytes memory a = new bytes(1000); // all zeros
        require(Deflate.compressRLE(a).length < 100, "flat run should compress well");
    }
}
