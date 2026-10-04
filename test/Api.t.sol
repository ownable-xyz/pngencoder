// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PNGEncoder.sol";
import "../src/Self.sol";
import "./PngDecode.sol";

/// Tests for the public API: the RLE encodings from RGBA input, the still-image
/// convenience functions, the APNG chunk patch functions, the splicing of
/// ancillary chunks, ERC-165 discovery and the self-describing fallback.
contract ApiTest is Test {
    PNGEncoder internal enc;

    function setUp() public {
        enc = new PNGEncoder();
    }

    // The palette and the fixtures have the same shapes as those in the golden
    // tests.
    function _palette() internal pure returns (uint32[] memory p) {
        p = new uint32[](4);
        p[0] = 0x102030FF;
        p[1] = 0xA0B0C080;
        p[2] = 0x40C080FF;
        p[3] = 0xE02040FF;
    }

    function _indices(uint16 w, uint16 h) internal pure returns (bytes memory idx) {
        idx = new bytes(uint256(w) * h);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                idx[y * w + x] = bytes1(uint8((y / 2) % 4));
            }
        }
    }

    function _rgba(uint16 w, uint16 h) internal pure returns (bytes memory px) {
        uint32[] memory p = _palette();
        px = new bytes(uint256(w) * h * 4);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint32 c = p[(y / 2) % 4];
                uint256 o = (y * w + x) * 4;
                px[o] = bytes1(uint8(c >> 24));
                px[o + 1] = bytes1(uint8(c >> 16));
                px[o + 2] = bytes1(uint8(c >> 8));
                px[o + 3] = bytes1(uint8(c));
            }
        }
    }

    function _mk(uint16 w, uint16 h, bytes memory layer) internal pure returns (Animation memory a) {
        a.frameCount = 1;
        a.width = w;
        a.height = h;
        a.frames = new bytes[](1);
        a.frames[0] = layer;
    }

    function _apng(uint16 w, uint16 h) internal pure returns (Animation memory a) {
        a.frameCount = 2;
        a.width = w;
        a.height = h;
        a.frames = new bytes[](2);
        a.delays = new uint16[](2);
        a.xOffsets = new uint16[](2);
        a.yOffsets = new uint16[](2);
        a.widths = new uint16[](2);
        a.heights = new uint16[](2);
        for (uint256 f = 0; f < 2; f++) {
            a.frames[f] = _rgba(w, h);
            a.delays[f] = 10;
            a.widths[f] = w;
            a.heights[f] = h;
        }
    }

    // ---- RLE via the Encoding enum ------------------------------------------

    function test_IndexedRLE_MatchesProvidedPalettePath() public view {
        // The extraction finds the colours in the same first-seen order as
        // _palette(). Thus the two paths must give the same bytes.
        bytes memory viaEnum = enc.getImageBuffer(_mk(8, 8, _rgba(8, 8)), 1, Encoding.IndexedRLE);
        bytes memory viaPalette = enc.getImageBufferIndexedRLE(_mk(8, 8, _indices(8, 8)), 1, _palette());
        assertEq(keccak256(viaEnum), keccak256(viaPalette), "IndexedRLE == provided-palette RLE");
    }

    function test_AutoRLE_ResolvesToIndexedRLE() public view {
        assertEq(
            keccak256(enc.getImageBuffer(_mk(8, 8, _rgba(8, 8)), 1, Encoding.AutoRLE)),
            keccak256(enc.getImageBuffer(_mk(8, 8, _rgba(8, 8)), 1, Encoding.IndexedRLE)),
            "AutoRLE resolves to IndexedRLE when indexable"
        );
    }

    function test_IndexedRLE_RoundTrips() public view {
        bytes memory png = enc.getImageBuffer(_mk(8, 8, _rgba(8, 8)), 1, Encoding.IndexedRLE);
        (,, uint8 ct, bytes memory rgba) = PngDecode.decode(png);
        assertEq(ct, 3, "colour type 3");
        assertEq(keccak256(rgba), keccak256(_rgba(8, 8)), "RLE round-trips");
    }

    // ---- still-image conveniences --------------------------------------------

    function test_StillConvenience_MatchesStructPath() public view {
        bytes memory rgba = _rgba(8, 8);
        assertEq(
            keccak256(enc.getDataUri(rgba, 8, 8, 2)),
            keccak256(enc.getDataUri(_mk(8, 8, rgba), 2)),
            "still getDataUri == struct getDataUri"
        );
        assertEq(
            keccak256(enc.getImageBuffer(rgba, 8, 8, 1, Encoding.IndexedDeflate)),
            keccak256(enc.getImageBuffer(_mk(8, 8, rgba), 1, Encoding.IndexedDeflate)),
            "still getImageBuffer == struct getImageBuffer"
        );
    }

    // ---- chunk patchers --------------------------------------------------------

    function test_WithLoopCount_PatchesAcTL() public view {
        bytes memory png = enc.getImageBuffer(_apng(8, 8), 1);
        bytes32 original = keccak256(png);

        bytes memory patched = enc.withLoopCount(png, 5);
        // acTL comes immediately after IHDR: 8 signature bytes + 25 bytes of
        // IHDR chunk = offset 33. num_plays is the second word of its data.
        uint256 playsOff = 33 + 8 + 4;
        assertEq(uint8(patched[playsOff + 3]), 5, "num_plays patched");
        // The CRC of the chunk must be the CRC of its tag and data.
        bytes memory tagAndData = new bytes(12);
        for (uint256 i = 0; i < 12; i++) {
            tagAndData[i] = patched[33 + 4 + i];
        }
        uint32 crc = (uint32(uint8(patched[49])) << 24) | (uint32(uint8(patched[50])) << 16)
            | (uint32(uint8(patched[51])) << 8) | uint32(uint8(patched[52]));
        assertEq(crc, enc.crc32(tagAndData), "acTL CRC rewritten correctly");

        // A patch back to the default of the encoder gives the original bytes.
        assertEq(keccak256(enc.withLoopCount(patched, 0)), original, "round-trip restores");
    }

    function test_WithFrameControl_PatchesFcTL() public view {
        bytes memory png = enc.getImageBuffer(_apng(8, 8), 1);
        bytes32 original = keccak256(png);

        // Frame 1: dispose = background, blend = source.
        bytes memory patched = enc.withFrameControl(png, 1, 1, 0);
        // The image still decodes (the pixels of frame 0 do not change).
        (,,, bytes memory rgba) = PngDecode.decode(patched);
        assertEq(keccak256(rgba), keccak256(_rgba(8, 8)), "still decodes after patch");

        // A patch back gives the original bytes.
        assertEq(keccak256(enc.withFrameControl(patched, 1, 0, 1)), original, "round-trip restores");
    }

    function test_Patchers_RevertOnMissingChunk() public {
        bytes memory still = enc.getImageBuffer(_mk(4, 4, _rgba(4, 4)), 1); // no acTL/fcTL
        vm.expectRevert(PNGEncoder.ChunkNotFound.selector);
        enc.withLoopCount(still, 3);
        vm.expectRevert(PNGEncoder.ChunkNotFound.selector);
        enc.withFrameControl(still, 0, 0, 0);
    }

    // ---- ancillary chunk splicing ------------------------------------------------

    function test_PngChunk_SplicesIntoWindowedStream() public view {
        uint32[] memory palette = new uint32[](2);
        palette[0] = 0x000000FF;
        palette[1] = 0xFFFFFFFF;
        bytes memory indices = new bytes(16); // 4x4, checker
        for (uint256 i = 0; i < 16; i++) {
            indices[i] = bytes1(uint8(i % 2));
        }

        bytes memory tEXt = enc.pngChunk("tEXt", bytes("Software\x00pngencoder"));
        bytes memory png = bytes.concat(enc.pngStreamPreamble(4, 4, 1, palette), tEXt, enc.pngStreamOpen());
        (bytes memory idat, uint32 adler) = enc.pngStreamBand(indices, 4, 1, true, 1);
        png = bytes.concat(png, idat, enc.pngStreamTrailer(adler));

        (uint256 w, uint256 h, uint8 ct,) = PngDecode.decode(png);
        assertEq(w, 4, "width survives the splice");
        assertEq(h, 4, "height survives the splice");
        assertEq(ct, 3, "indexed");
        // The preamble and the opener together are equal to the header.
        assertEq(
            keccak256(bytes.concat(enc.pngStreamPreamble(4, 4, 1, palette), enc.pngStreamOpen())),
            keccak256(enc.pngStreamHeader(4, 4, 1, palette)),
            "header == preamble + open"
        );
    }

    // ---- discoverability -----------------------------------------------------------

    function test_SupportsInterface() public view {
        assertTrue(enc.supportsInterface(type(IPNGEncoder).interfaceId), "IPNGEncoder");
        assertTrue(enc.supportsInterface(type(IAnimationEncoder).interfaceId), "IAnimationEncoder");
        assertTrue(enc.supportsInterface(0x01ffc9a7), "ERC-165 itself");
        assertFalse(enc.supportsInterface(0xffffffff), "not the ERC-165 sentinel");
    }

    function test_Self_Describe() public {
        (bool ok, bytes memory ret) = address(enc).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        assertFalse(ok, "unknown call must revert");
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 0x20))
        }
        assertEq(sel, Self.Describe.selector, "reverts with Self.Describe");
        // Remove the selector, then decode the descriptor.
        bytes memory payload = new bytes(ret.length - 4);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = ret[i + 4];
        }
        bytes memory descriptor = abi.decode(payload, (bytes));
        assertTrue(descriptor.length > 100, "descriptor present");
    }

    /// The signature lines of the descriptor must be canonical: the keccak hash
    /// of each line gives its real selector. The test compares the XOR of all
    /// line selectors with the interfaceId from the compiler, plus the utility
    /// functions that the interface does not declare. Thus one incorrect tuple
    /// string makes the test fail.
    function test_Self_SignaturesAreCanonical() public {
        (, bytes memory ret) = address(enc).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        bytes memory payload = new bytes(ret.length - 4);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = ret[i + 4];
        }
        bytes memory d = abi.decode(payload, (bytes));

        // Go through the lines after the prose header. The header ends at the
        // first \n.
        uint256 start = 0;
        while (d[start] != 0x0a) start++;
        start++;

        bytes4 acc;
        uint256 count;
        uint256 lineStart = start;
        for (uint256 i = start; i < d.length; i++) {
            if (d[i] == 0x0a) {
                bytes memory line = new bytes(i - lineStart);
                for (uint256 j = 0; j < line.length; j++) {
                    line[j] = d[lineStart + j];
                }
                acc ^= bytes4(keccak256(line));
                count++;
                lineStart = i + 1;
            }
        }

        bytes4 expected = type(IPNGEncoder).interfaceId ^ bytes4(keccak256("crc32(bytes)"))
            ^ bytes4(keccak256("crc32WithStart(uint32,bytes)")) ^ bytes4(keccak256("crc32WithStart(uint32,bytes,bool)"))
            ^ type(IERC165).interfaceId;
        assertEq(count, 32, "all 32 functions listed");
        assertEq(acc, expected, "every line is a canonical signature");
    }

    // ---- string-returning URI twins ------------------------------------------

    /// Each `getDataUri*String` twin must give the same bytes as its `bytes`
    /// original, as a `string`. A twin only lets `tokenURI` return the value
    /// without a cast. It has no behaviour of its own.
    function test_StringTwins_EqualByteForms() public view {
        Animation memory a = _mk(8, 8, _rgba(8, 8));
        bytes memory rgba = _rgba(8, 8);
        uint32[] memory pal = _palette();
        Animation memory idx = _mk(8, 8, _indices(8, 8));

        assertEq(keccak256(bytes(enc.getDataUriString(a, 2))), keccak256(enc.getDataUri(a, 2)), "getDataUriString");
        assertEq(
            keccak256(bytes(enc.getDataUriString(a, 1, Encoding.AutoDeflate))),
            keccak256(enc.getDataUri(a, 1, Encoding.AutoDeflate)),
            "getDataUriString(encoding)"
        );
        assertEq(
            keccak256(bytes(enc.getDataUriString(rgba, 8, 8, 2))),
            keccak256(enc.getDataUri(rgba, 8, 8, 2)),
            "still getDataUriString"
        );
        assertEq(
            keccak256(bytes(enc.getDataUriString(rgba, 8, 8, 1, Encoding.IndexedDeflate))),
            keccak256(enc.getDataUri(rgba, 8, 8, 1, Encoding.IndexedDeflate)),
            "still getDataUriString(encoding)"
        );
        assertEq(
            keccak256(bytes(enc.getDataUriIndexedString(idx, 1, pal, true))),
            keccak256(enc.getDataUriIndexed(idx, 1, pal, true)),
            "getDataUriIndexedString"
        );
        assertEq(
            keccak256(bytes(enc.getDataUriIndexedRLEString(idx, 1, pal))),
            keccak256(enc.getDataUriIndexedRLE(idx, 1, pal)),
            "getDataUriIndexedRLEString"
        );
    }
}
