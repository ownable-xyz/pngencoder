// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PNGEncoder.sol";
import "./PngDecode.sol";

/// Tests the indexed-colour path. The test encodes an image, decodes the PNG
/// back to pixels and makes sure that the pixels are the same as the source.
/// The decoder is a minimal reader for the output of this encoder (colour type
/// 3, filter NONE, stored DEFLATE, scaleFactor 1).
contract IndexedTest is Test {
    PNGEncoder internal enc;

    function setUp() public {
        enc = new PNGEncoder();
    }

    // ---- fixtures ----------------------------------------------------------

    function _mk(uint16 w, uint16 h, bytes memory rgba) internal pure returns (Animation memory a) {
        a.frameCount = 1;
        a.width = w;
        a.height = h;
        a.frames = new bytes[](1);
        a.frames[0] = rgba;
    }

    // 8x8, three colours (one semi-transparent). The first-seen order is red,
    // green, blue.
    function _paletteImg() internal pure returns (Animation memory a, bytes memory rgba) {
        uint16 w = 8;
        uint16 h = 8;
        uint32[3] memory col = [uint32(0xC82828FF), 0x28C82880, 0x2828C8FF]; // RRGGBBAA
        rgba = new bytes(uint256(w) * h * 4);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint32 c = col[(x + y) % 3];
                uint256 o = (y * w + x) * 4;
                rgba[o] = bytes1(uint8(c >> 24));
                rgba[o + 1] = bytes1(uint8(c >> 16));
                rgba[o + 2] = bytes1(uint8(c >> 8));
                rgba[o + 3] = bytes1(uint8(c));
            }
        }
        a = _mk(w, h, rgba);
    }

    // 20x20 with more than 256 different colours (not indexable).
    function _manyImg() internal pure returns (Animation memory a) {
        uint16 w = 20;
        uint16 h = 20;
        bytes memory rgba = new bytes(uint256(w) * h * 4);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint256 o = (y * w + x) * 4;
                rgba[o] = bytes1(uint8(x * 13));
                rgba[o + 1] = bytes1(uint8(y * 13));
                rgba[o + 2] = bytes1(uint8((x + y) * 7));
                rgba[o + 3] = bytes1(uint8(255));
            }
        }
        a = _mk(w, h, rgba);
    }

    // ---- tests -------------------------------------------------------------

    function test_Indexed_RoundTrip() public view {
        (Animation memory a, bytes memory src) = _paletteImg();
        bytes memory png = enc.getImageBuffer(a, 1, Encoding.Indexed);
        (uint256 w, uint256 h, uint8 colorType, bytes memory rgba) = PngDecode.decode(png);
        assertEq(colorType, 3, "colour type 3 (indexed)");
        assertEq(w, 8, "width");
        assertEq(h, 8, "height");
        assertEq(keccak256(rgba), keccak256(src), "round-trip reconstructs the source pixels");
    }

    function test_ResolveEncoding() public view {
        (Animation memory a,) = _paletteImg();
        assertEq(uint256(enc.resolveEncoding(a)), uint256(Encoding.Indexed), "few colours -> indexed");
        assertEq(uint256(enc.resolveEncoding(_manyImg())), uint256(Encoding.TrueColor), "many colours -> truecolor");
    }

    function test_Auto_FallsBackToTrueColor() public view {
        Animation memory a = _manyImg();
        assertEq(
            keccak256(enc.getImageBuffer(a, 1, Encoding.Auto)),
            keccak256(enc.getImageBuffer(a, 1)),
            "auto == truecolor when not indexable"
        );
    }

    function test_Indexed_RevertsWhenTooManyColors() public {
        Animation memory a = _manyImg();
        vm.expectRevert(PNGEncoder.NotIndexable.selector);
        enc.getImageBuffer(a, 1, Encoding.Indexed);
    }

    function test_Indexed_SmallerThanTrueColor() public {
        (Animation memory a,) = _paletteImg();
        uint256 indexedLen = enc.getImageBuffer(a, 1, Encoding.Indexed).length;
        uint256 truecolorLen = enc.getImageBuffer(a, 1).length;
        emit log_named_uint("truecolor bytes", truecolorLen);
        emit log_named_uint("indexed bytes  ", indexedLen);
        assertLt(indexedLen, truecolorLen, "indexed output is smaller");
    }

    // 128x128 with `nColors` different colours in bands: an indexable canvas.
    function _bandImg(uint16 w, uint16 h, uint256 nColors) internal pure returns (Animation memory a) {
        bytes memory rgba = new bytes(uint256(w) * h * 4);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint256 c = ((x + y) / 8) % nColors;
                uint256 o = (y * w + x) * 4;
                rgba[o] = bytes1(uint8(c * 7));
                rgba[o + 1] = bytes1(uint8(c * 11));
                rgba[o + 2] = bytes1(uint8(c * 13));
                rgba[o + 3] = bytes1(uint8(255));
            }
        }
        a = _mk(w, h, rgba);
    }

    function test_Sizes_128() public {
        Animation memory a = _bandImg(128, 128, 32);
        uint256 tc = enc.getImageBuffer(a, 1).length;
        uint256 ix = enc.getImageBuffer(a, 1, Encoding.Indexed).length;
        emit log_named_uint("128x128 32-colour  truecolor bytes", tc);
        emit log_named_uint("128x128 32-colour  indexed   bytes", ix);
        assertLt(ix * 3, tc, "indexed is well under a third the size");
    }

    function test_EncodeGas_IndexedDeflate_128() public {
        Animation memory a = _bandImg(128, 128, 32);
        uint256 g = gasleft();
        enc.getImageBuffer(a, 1, Encoding.IndexedDeflate);
        emit log_named_uint("encode gas  IndexedDeflate 128x128", g - gasleft());
    }

    // The gas to encode. Each measurement is in its own call (new memory), so
    // the comparison is fair.
    function test_EncodeGas_TrueColor_128() public {
        Animation memory a = _bandImg(128, 128, 32);
        uint256 g = gasleft();
        enc.getImageBuffer(a, 1);
        emit log_named_uint("encode gas  truecolor 128x128", g - gasleft());
    }

    function test_EncodeGas_Indexed_128() public {
        Animation memory a = _bandImg(128, 128, 32);
        uint256 g = gasleft();
        enc.getImageBuffer(a, 1, Encoding.Indexed);
        emit log_named_uint("encode gas  indexed   128x128", g - gasleft());
    }

    // An animation with 2 frames that share one palette of 3 colours.
    function _twoFrame() internal pure returns (Animation memory a, bytes memory frame0) {
        uint16 w = 6;
        uint16 h = 6;
        uint32[3] memory col = [uint32(0xC82828FF), 0x28C82880, 0x2828C8FF];
        frame0 = new bytes(uint256(w) * h * 4);
        bytes memory frame1 = new bytes(uint256(w) * h * 4);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint256 o = (y * w + x) * 4;
                _writeColor(frame0, o, col[(x + y) % 3]);
                _writeColor(frame1, o, col[(x + y + 1) % 3]);
            }
        }
        a.frameCount = 2;
        a.width = w;
        a.height = h;
        a.frames = new bytes[](2);
        a.frames[0] = frame0;
        a.frames[1] = frame1;
        a.delays = new uint16[](2);
        a.xOffsets = new uint16[](2);
        a.yOffsets = new uint16[](2);
        a.widths = new uint16[](2);
        a.heights = new uint16[](2);
        for (uint256 i = 0; i < 2; i++) {
            a.widths[i] = w;
            a.heights[i] = h;
            a.delays[i] = 10;
        }
    }

    function _writeColor(bytes memory b, uint256 o, uint32 c) internal pure {
        b[o] = bytes1(uint8(c >> 24));
        b[o + 1] = bytes1(uint8(c >> 16));
        b[o + 2] = bytes1(uint8(c >> 8));
        b[o + 3] = bytes1(uint8(c));
    }

    // Indexed APNG: the data of frame 0 is in IDAT. The decoded data must be
    // the same as the source.
    function test_Indexed_APNG_Frame0() public view {
        (Animation memory a, bytes memory frame0) = _twoFrame();
        bytes memory png = enc.getImageBuffer(a, 1, Encoding.Indexed);
        (,, uint8 colorType, bytes memory rgba) = PngDecode.decode(png);
        assertEq(colorType, 3, "colour type 3");
        assertEq(keccak256(rgba), keccak256(frame0), "APNG frame 0 (IDAT) round-trips");
    }

    function test_IndexedDeflate_RoundTrip() public view {
        (Animation memory a, bytes memory src) = _paletteImg();
        bytes memory png = enc.getImageBuffer(a, 1, Encoding.IndexedDeflate);
        (,, uint8 colorType, bytes memory rgba) = PngDecode.decode(png);
        assertEq(colorType, 3, "colour type 3");
        assertEq(keccak256(rgba), keccak256(src), "indexed DEFLATE round-trips");
    }

    function test_TrueColorDeflate_RoundTrip() public view {
        (Animation memory a, bytes memory src) = _paletteImg();
        bytes memory png = enc.getImageBuffer(a, 1, Encoding.TrueColorDeflate);
        (,, uint8 colorType, bytes memory rgba) = PngDecode.decode(png);
        assertEq(colorType, 6, "colour type 6 (truecolor)");
        assertEq(keccak256(rgba), keccak256(src), "truecolor DEFLATE round-trips");
    }

    function test_Deflate_ShrinksFlatBands() public {
        Animation memory a = _bandImg(128, 128, 32);
        uint256 stored = enc.getImageBuffer(a, 1, Encoding.Indexed).length;
        uint256 deflated = enc.getImageBuffer(a, 1, Encoding.IndexedDeflate).length;
        emit log_named_uint("indexed stored  bytes", stored);
        emit log_named_uint("indexed deflate bytes", deflated);
        assertLt(deflated, stored, "DEFLATE shrinks the flat bands further");
    }

    // A smooth horizontal ramp: each row is 0,1,2,... The rows have no runs
    // until the Sub filter changes each row into a run of 1s.
    function _rampImg(uint16 w, uint16 h) internal pure returns (Animation memory a) {
        bytes memory rgba = new bytes(uint256(w) * h * 4);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint256 o = (y * w + x) * 4;
                rgba[o] = bytes1(uint8(x));
                rgba[o + 1] = bytes1(uint8(x));
                rgba[o + 2] = bytes1(uint8(x));
                rgba[o + 3] = bytes1(uint8(255));
            }
        }
        a = _mk(w, h, rgba);
    }

    function test_Filter_ShrinksGradient() public {
        Animation memory a = _rampImg(200, 32); // 200 distinct greys
        uint256 stored = enc.getImageBuffer(a, 1, Encoding.Indexed).length;
        uint256 deflated = enc.getImageBuffer(a, 1, Encoding.IndexedDeflate).length;
        emit log_named_uint("ramp indexed stored  bytes", stored);
        emit log_named_uint("ramp indexed deflate bytes", deflated);
        assertLt(deflated * 4, stored, "Sub filter + RLE crushes a gradient");
    }

    // ---- provided-palette fast path ---------------------------------------

    function test_ProvidedPalette_RoundTrip() public view {
        uint32[] memory palette = new uint32[](3);
        palette[0] = 0xC82828FF;
        palette[1] = 0x28C82880; // semi-transparent -> exercises tRNS
        palette[2] = 0x2828C8FF;

        uint16 w = 8;
        uint16 h = 8;
        bytes memory idx = new bytes(uint256(w) * h); // one index per pixel
        bytes memory expected = new bytes(uint256(w) * h * 4);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint256 p = (x + y) % 3;
                idx[y * w + x] = bytes1(uint8(p));
                _writeColor(expected, (y * w + x) * 4, palette[p]);
            }
        }

        Animation memory a = _mk(w, h, idx); // the frame holds the indices
        bytes memory png = enc.getImageBufferIndexed(a, 1, palette, true); // deflate
        (,, uint8 colorType, bytes memory rgba) = PngDecode.decode(png);
        assertEq(colorType, 3, "colour type 3");
        assertEq(keccak256(rgba), keccak256(expected), "provided-palette round-trips");
    }

    function test_ProvidedPalette_RevertsTooLarge() public {
        uint32[] memory palette = new uint32[](257);
        Animation memory a = _mk(1, 1, new bytes(1));
        vm.expectRevert(PNGEncoder.PaletteTooLarge.selector);
        enc.getImageBufferIndexed(a, 1, palette, false);
    }
}
