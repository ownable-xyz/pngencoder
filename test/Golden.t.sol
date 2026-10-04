// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PNGEncoder.sol";

/// Byte-exact regression pins for each consumption path. The test encodes each
/// fixed fixture and compares the `keccak` hash of the output with a recorded
/// constant. Thus a change in the output bytes causes a failure. With these
/// pins, you can optimize the hot paths and know that the output stays the
/// same. Change a pin only when a byte change is intended.
contract GoldenTest is Test {
    PNGEncoder internal enc;

    function setUp() public {
        enc = new PNGEncoder();
    }

    // Four colours in a fixed order. One colour is semi-transparent (this uses
    // tRNS).
    function _palette() internal pure returns (uint32[] memory p) {
        p = new uint32[](4);
        p[0] = 0x102030FF;
        p[1] = 0xA0B0C080; // semi-transparent -> tRNS
        p[2] = 0x40C080FF;
        p[3] = 0xE02040FF;
    }

    // 8x8, horizontal colour bands of two rows. The filters and LZ77 compress
    // these runs well.
    function _indices(uint16 w, uint16 h, uint256 shift) internal pure returns (bytes memory idx) {
        idx = new bytes(uint256(w) * h);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                idx[y * w + x] = bytes1(uint8((y / 2 + shift) % 4));
            }
        }
    }

    function _rgba(uint16 w, uint16 h, uint256 shift) internal pure returns (bytes memory px) {
        uint32[] memory p = _palette();
        px = new bytes(uint256(w) * h * 4);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint32 c = p[(y / 2 + shift) % 4];
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

    // An animation with two frames. The bands of the second frame are shifted.
    function _anim(bool isIndexed) internal pure returns (Animation memory a) {
        uint16 w = 8;
        uint16 h = 8;
        a.frameCount = 2;
        a.width = w;
        a.height = h;
        a.frames = new bytes[](2);
        for (uint256 f = 0; f < 2; f++) {
            a.frames[f] = isIndexed ? _indices(w, h, f) : _rgba(w, h, f);
        }
        a.delays = new uint16[](2);
        a.xOffsets = new uint16[](2);
        a.yOffsets = new uint16[](2);
        a.widths = new uint16[](2);
        a.heights = new uint16[](2);
        for (uint256 f = 0; f < 2; f++) {
            a.delays[f] = 10;
            a.widths[f] = w;
            a.heights[f] = h;
        }
    }

    function _rgbaAnim() internal pure returns (Animation memory a) {
        return _mk(8, 8, _rgba(8, 8, 0));
    }

    function _idxAnim() internal pure returns (Animation memory a) {
        return _mk(8, 8, _indices(8, 8, 0));
    }

    // ---- pinned outputs (change only for an intended byte change) ----------

    bytes32 constant G_TC = 0x6ba633c40aeaf99ce985b33d55a6dacf0d242f3c1bebe86d9018e77f05aca40d;
    bytes32 constant G_IDX = 0x820ff0f7c1694c26ffcee1f3e8d44234a3086069fbcf79ffe215c529ce940770;
    bytes32 constant G_IDX_DEF = 0xdb59c833fd9a86630042bb7afb37e972e9724f793bae2688b9948231db4ff69b;
    bytes32 constant G_TC_DEF = 0xbe60aa0821ed369d734d22a2fe35ec70fd60867c49fcb57023f2f73aa8c8da75;
    bytes32 constant G_IDX_DEF_X3 = 0x1d8ac2b8af0a1d9786b9e0dd505b4839bf5218a830fce314fae3cbba016a0796;
    bytes32 constant G_PAL_URI_DEF = 0xec727789817e059fd2f66895f5a3c9afdbea1c08128a9b0561cbbb371e28a253;
    bytes32 constant G_APNG_TC = 0x66535f261192cb8ce5b354a30a603bd3f134ef7cf0e981d0f75b8591b88f4d6d;
    // This pin is for the RGBA fixture. It is equal to the output of the
    // provided-palette path (test_Golden_APNG compares the two). Do not give
    // index bytes to the RGBA extraction path: input validation rejects them.
    bytes32 constant G_APNG_IDX_DEF = 0xf8eb84f69a5e8f4edbfdc714ec04d01242ed0323348179dfcaa4d50ac97e0923;

    // ---- still image, RGBA input ------------------------------------------

    function test_Golden_TrueColor() public view {
        assertEq(keccak256(enc.getImageBuffer(_rgbaAnim(), 1)), G_TC, "truecolor drift");
        assertEq(
            keccak256(enc.getImageBuffer(_rgbaAnim(), 1, Encoding.TrueColorDeflate)),
            G_TC_DEF,
            "truecolor deflate drift"
        );
    }

    function test_Golden_Indexed() public view {
        assertEq(keccak256(enc.getImageBuffer(_rgbaAnim(), 1, Encoding.Indexed)), G_IDX, "indexed drift");
        assertEq(
            keccak256(enc.getImageBuffer(_rgbaAnim(), 1, Encoding.IndexedDeflate)), G_IDX_DEF, "indexed deflate drift"
        );
        // Auto gives Indexed for this image, which has few colours.
        assertEq(
            keccak256(enc.getImageBuffer(_rgbaAnim(), 1, Encoding.AutoDeflate)),
            G_IDX_DEF,
            "auto-deflate resolves to indexed-deflate"
        );
    }

    function test_Golden_Indexed_Scaled() public view {
        assertEq(
            keccak256(enc.getImageBuffer(_rgbaAnim(), 3, Encoding.IndexedDeflate)),
            G_IDX_DEF_X3,
            "indexed deflate x3 drift"
        );
    }

    // ---- still image, caller-supplied palette + indices --------------------

    function test_Golden_ProvidedPalette() public view {
        uint32[] memory p = _palette();
        // Extraction from the RGBA image (first-seen order) gives the same
        // palette as the supplied palette. Thus the two paths must give the
        // same bytes.
        assertEq(
            keccak256(enc.getImageBufferIndexed(_idxAnim(), 1, p, false)),
            G_IDX,
            "provided-palette == extracted indexed"
        );
        assertEq(
            keccak256(enc.getImageBufferIndexed(_idxAnim(), 1, p, true)),
            G_IDX_DEF,
            "provided-palette deflate == extracted indexed deflate"
        );
        assertEq(
            keccak256(enc.getDataUriIndexed(_idxAnim(), 1, p, true)),
            G_PAL_URI_DEF,
            "provided-palette deflate data URI drift"
        );
    }

    // ---- run-length tier ----------------------------------------------------

    bytes32 constant G_IDX_RLE = 0x37494aee9ba92de20ef8faa0cd911e2d3b1547dfda6ca2c98ae4a9a7deb96460;

    function test_Golden_IndexedRLE() public view {
        assertEq(keccak256(enc.getImageBufferIndexedRLE(_idxAnim(), 1, _palette())), G_IDX_RLE, "indexed RLE drift");
    }

    function test_LogGoldenRLE() public {
        emit log_named_bytes32("G_IDX_RLE", keccak256(enc.getImageBufferIndexedRLE(_idxAnim(), 1, _palette())));
    }

    // ---- animation (APNG) --------------------------------------------------

    function test_Golden_APNG() public view {
        assertEq(keccak256(enc.getImageBuffer(_anim(false), 1)), G_APNG_TC, "APNG truecolor drift");
        // The extraction path (RGBA input) and the provided-palette path (index
        // input) must give the same bytes. Extraction finds the colours in the
        // same first-seen order as _palette().
        bytes32 extracted = keccak256(enc.getImageBuffer(_anim(false), 1, Encoding.IndexedDeflate));
        assertEq(extracted, G_APNG_IDX_DEF, "APNG indexed deflate drift");
        assertEq(
            keccak256(enc.getImageBufferIndexed(_anim(true), 1, _palette(), true)),
            extracted,
            "APNG provided-palette == extracted"
        );
    }

    function test_LogGoldenAPNG() public {
        emit log_named_bytes32(
            "G_APNG_IDX_DEF", keccak256(enc.getImageBuffer(_anim(false), 1, Encoding.IndexedDeflate))
        );
    }
}
