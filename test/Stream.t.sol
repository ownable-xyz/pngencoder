// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PNGEncoder.sol";
import "./PngDecode.sol";

/// Tests windowed encoding. The test builds a still image with one band of rows
/// for each call. It makes sure that the joined PNG decodes to the same pixels
/// as the one-shot encode of the same input. The cases include the two colour
/// types, scale and bands of unequal size.
contract StreamTest is Test {
    PNGEncoder internal enc;

    bytes32 constant G_WIN_STORED = 0xa06ea9872752f41a66f9ad7b85c20fe5a642ea165431621f24326804da493453;
    bytes32 constant G_WIN_DEFLATE = 0x97bfadd17f2f3e9e0f8eb9968856e6c251ba05e474d3b5561fd2f4325c6c3073;

    function setUp() public {
        enc = new PNGEncoder();
    }

    function _mk(uint16 w, uint16 h, bytes memory pixels) internal pure returns (Animation memory a) {
        a.frameCount = 1;
        a.width = w;
        a.height = h;
        a.frames = new bytes[](1);
        a.frames[0] = pixels;
    }

    function _sliceRows(bytes memory data, uint256 rowStart, uint256 rowCount, uint256 rowBytes)
        internal
        pure
        returns (bytes memory r)
    {
        r = new bytes(rowCount * rowBytes);
        uint256 start = rowStart * rowBytes;
        for (uint256 i = 0; i < r.length; i++) {
            r[i] = data[start + i];
        }
    }

    function _assemble(bytes memory pixels, uint16 w, uint16 h, uint8 scale, uint32[] memory palette, uint256 bandRows)
        internal
        view
        returns (bytes memory png)
    {
        return _assemble(pixels, w, h, scale, palette, bandRows, false);
    }

    function _assemble(
        bytes memory pixels,
        uint16 w,
        uint16 h,
        uint8 scale,
        uint32[] memory palette,
        uint256 bandRows,
        bool deflate
    ) internal view returns (bytes memory png) {
        uint256 rowBytes = palette.length > 0 ? uint256(w) : uint256(w) * 4;
        png = enc.pngStreamHeader(w, h, scale, palette);
        uint32 adler = 1;
        for (uint256 r = 0; r < h; r += bandRows) {
            uint256 rc = r + bandRows > h ? h - r : bandRows;
            bytes memory idat;
            (idat, adler) = _band(_sliceRows(pixels, r, rc, rowBytes), w, scale, palette.length > 0, adler, deflate);
            png = bytes.concat(png, idat);
        }
        png = bytes.concat(png, enc.pngStreamTrailer(adler));
    }

    /// @dev Encodes one band to its IDAT chunk, stored or compressed, and gives
    /// back the new Adler value.
    function _band(bytes memory band, uint16 w, uint8 scale, bool isIndexed, uint32 adler, bool deflate)
        internal
        view
        returns (bytes memory idat, uint32 newAdler)
    {
        if (deflate) return enc.pngStreamBandDeflate(band, w, scale, isIndexed, adler);
        return enc.pngStreamBand(band, w, scale, isIndexed, adler);
    }

    // ---- indexed ----------------------------------------------------------

    function _indexedFixture() internal pure returns (uint32[] memory palette, bytes memory indices) {
        palette = new uint32[](3);
        palette[0] = 0xC82828FF;
        palette[1] = 0x28C82880; // semi-transparent -> tRNS
        palette[2] = 0x2828C8FF;
        uint16 w = 8;
        uint16 h = 13; // not a multiple of the band size -> uneven last band
        indices = new bytes(uint256(w) * h);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                indices[y * w + x] = bytes1(uint8((x * 2 + y) % 3));
            }
        }
    }

    function test_Stream_Indexed_MatchesOneShot() public view {
        (uint32[] memory palette, bytes memory indices) = _indexedFixture();
        bytes memory oneShot = enc.getImageBufferIndexed(_mk(8, 13, indices), 1, palette, false);
        bytes memory banded = _assemble(indices, 8, 13, 1, palette, 4);

        (uint256 w, uint256 h, uint8 ct, bytes memory pixels) = PngDecode.decode(banded);
        (,,, bytes memory oneShotPixels) = PngDecode.decode(oneShot);
        assertEq(ct, 3, "indexed colour type");
        assertEq(w, 8, "width");
        assertEq(h, 13, "height");
        assertEq(keccak256(pixels), keccak256(oneShotPixels), "banded indexed == one-shot");
    }

    function test_Stream_Indexed_Scaled_MatchesOneShot() public view {
        (uint32[] memory palette, bytes memory indices) = _indexedFixture();
        bytes memory oneShot = enc.getImageBufferIndexed(_mk(8, 13, indices), 3, palette, false);
        bytes memory banded = _assemble(indices, 8, 13, 3, palette, 4);
        (,,, bytes memory pixels) = PngDecode.decode(banded);
        (,,, bytes memory oneShotPixels) = PngDecode.decode(oneShot);
        assertEq(keccak256(pixels), keccak256(oneShotPixels), "banded indexed x3 == one-shot");
    }

    // ---- truecolor --------------------------------------------------------

    function test_Stream_TrueColor_MatchesOneShot() public view {
        uint16 w = 6;
        uint16 h = 10;
        bytes memory rgba = new bytes(uint256(w) * h * 4);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint256 o = (y * w + x) * 4;
                rgba[o] = bytes1(uint8(x * 20));
                rgba[o + 1] = bytes1(uint8(y * 20));
                rgba[o + 2] = bytes1(uint8(128));
                rgba[o + 3] = bytes1(uint8(255));
            }
        }
        bytes memory oneShot = enc.getImageBuffer(_mk(w, h, rgba), 2);
        bytes memory banded = _assemble(rgba, w, h, 2, new uint32[](0), 3);

        (,, uint8 ct, bytes memory pixels) = PngDecode.decode(banded);
        (,,, bytes memory oneShotPixels) = PngDecode.decode(oneShot);
        assertEq(ct, 6, "truecolor colour type");
        assertEq(keccak256(pixels), keccak256(oneShotPixels), "banded truecolor x2 == one-shot");
    }

    // ---- windowed byte-exact pins -----------------------------------------
    // These pins fix the assembled windowed bytes. An optimization of the band
    // paths must not change the bytes that a client makes from a sequence of
    // calls. Change a pin only for an intended change.

    function test_LogWindowedGoldens() public {
        (uint32[] memory palette, bytes memory indices) = _indexedFixture();
        emit log_named_bytes32("G_WIN_STORED", keccak256(_assemble(indices, 8, 13, 1, palette, 4, false)));
        emit log_named_bytes32("G_WIN_DEFLATE", keccak256(_assemble(indices, 8, 13, 1, palette, 4, true)));
    }

    function test_Golden_Windowed_Stored() public view {
        (uint32[] memory palette, bytes memory indices) = _indexedFixture();
        assertEq(keccak256(_assemble(indices, 8, 13, 1, palette, 4, false)), G_WIN_STORED, "windowed stored drift");
    }

    function test_Golden_Windowed_Deflate() public view {
        (uint32[] memory palette, bytes memory indices) = _indexedFixture();
        assertEq(keccak256(_assemble(indices, 8, 13, 1, palette, 4, true)), G_WIN_DEFLATE, "windowed compressed drift");
    }

    // ---- compressed bands -------------------------------------------------

    function test_Stream_Deflate_Indexed_MatchesOneShot() public view {
        (uint32[] memory palette, bytes memory indices) = _indexedFixture();
        bytes memory oneShot = enc.getImageBufferIndexed(_mk(8, 13, indices), 1, palette, false);
        bytes memory banded = _assemble(indices, 8, 13, 1, palette, 4, true);

        (uint256 w, uint256 h, uint8 ct, bytes memory pixels) = PngDecode.decode(banded);
        (,,, bytes memory oneShotPixels) = PngDecode.decode(oneShot);
        assertEq(ct, 3, "indexed colour type");
        assertEq(w, 8, "width");
        assertEq(h, 13, "height");
        assertEq(keccak256(pixels), keccak256(oneShotPixels), "compressed-banded indexed == one-shot");
    }

    function test_Stream_Deflate_Indexed_Scaled_MatchesOneShot() public view {
        (uint32[] memory palette, bytes memory indices) = _indexedFixture();
        bytes memory oneShot = enc.getImageBufferIndexed(_mk(8, 13, indices), 3, palette, false);
        bytes memory banded = _assemble(indices, 8, 13, 3, palette, 4, true);
        (,,, bytes memory pixels) = PngDecode.decode(banded);
        (,,, bytes memory oneShotPixels) = PngDecode.decode(oneShot);
        assertEq(keccak256(pixels), keccak256(oneShotPixels), "compressed-banded indexed x3 == one-shot");
    }

    function test_Stream_Deflate_TrueColor_MatchesOneShot() public view {
        uint16 w = 6;
        uint16 h = 10;
        bytes memory rgba = new bytes(uint256(w) * h * 4);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint256 o = (y * w + x) * 4;
                rgba[o] = bytes1(uint8(x * 20));
                rgba[o + 1] = bytes1(uint8(y * 20));
                rgba[o + 2] = bytes1(uint8(128));
                rgba[o + 3] = bytes1(uint8(255));
            }
        }
        bytes memory oneShot = enc.getImageBuffer(_mk(w, h, rgba), 2);
        bytes memory banded = _assemble(rgba, w, h, 2, new uint32[](0), 3, true);

        (,, uint8 ct, bytes memory pixels) = PngDecode.decode(banded);
        (,,, bytes memory oneShotPixels) = PngDecode.decode(oneShot);
        assertEq(ct, 6, "truecolor colour type");
        assertEq(keccak256(pixels), keccak256(oneShotPixels), "compressed-banded truecolor x2 == one-shot");
    }

    // A larger canvas of repeated bands that compresses well. The compressed
    // output is clearly smaller than the stored output, also when many
    // independent windows divide the canvas.
    function test_Stream_Deflate_SmallerThanStored() public {
        uint16 w = 32;
        uint16 h = 48;
        uint32[] memory palette = new uint32[](4);
        palette[0] = 0x101018FF;
        palette[1] = 0xC8A000FF;
        palette[2] = 0x40C0A0FF;
        palette[3] = 0xE0E0E0FF;
        bytes memory indices = new bytes(uint256(w) * h);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                indices[y * w + x] = bytes1(uint8((y / 4) % 4)); // horizontal bands -> long runs
            }
        }
        bytes memory stored = _assemble(indices, w, h, 1, palette, 8, false);
        bytes memory deflated = _assemble(indices, w, h, 1, palette, 8, true);

        // The two outputs decode to the same pixels.
        (,,, bytes memory a) = PngDecode.decode(stored);
        (,,, bytes memory b) = PngDecode.decode(deflated);
        assertEq(keccak256(a), keccak256(b), "stored and compressed bands decode identically");

        // The compressed windowed output is much smaller.
        emit log_named_uint("stored-banded    bytes", stored.length);
        emit log_named_uint("compressed-banded bytes", deflated.length);
        assertLt(deflated.length, stored.length, "compressed bands are smaller than stored bands");
    }
}
