// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PNGEncoder.sol";

contract PNGEncoderTest is Test {
    PNGEncoder internal enc;

    function setUp() public {
        enc = new PNGEncoder();
    }

    // A fixed 4x4 RGBA image with deterministic pixels. The byte-exact pin uses
    // this image.
    function _img() internal pure returns (Animation memory a) {
        a.frameCount = 1;
        a.width = 4;
        a.height = 4;
        a.frames = new bytes[](1);
        bytes memory px = new bytes(4 * 4 * 4);
        for (uint256 i = 0; i < px.length; i++) {
            px[i] = bytes1(uint8((i * 7 + 3) & 0xff));
        }
        a.frames[0] = px;
    }

    // An NxN RGBA image for the gas tests. Assembly fills the pixels (fast).
    function _square(uint16 n) internal pure returns (Animation memory a) {
        a.frameCount = 1;
        a.width = n;
        a.height = n;
        a.frames = new bytes[](1);
        bytes memory px = new bytes(uint256(n) * n * 4);
        assembly {
            let p := add(px, 0x20)
            let e := add(p, mload(px))
            let v := 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20
            for {} lt(p, e) { p := add(p, 0x20) } {
                mstore(p, v)
                v := add(v, 1)
            }
        }
        a.frames[0] = px;
    }

    // ---- structural validity ----------------------------------------------
    function test_PngSignature() public view {
        bytes memory b = enc.getImageBuffer(_img(), 1);
        bytes8 sig;
        assembly {
            sig := mload(add(b, 0x20))
        }
        assertEq(bytes8(sig), bytes8(hex"89504E470D0A1A0A"), "PNG signature");
    }

    function test_IhdrDimsAndFormat() public view {
        bytes memory b = enc.getImageBuffer(_img(), 1);
        // The IHDR data starts at offset 16: 8 signature bytes + 4 length bytes
        // + 4 bytes of "IHDR".
        // width(4) height(4) bitdepth(1) colortype(1) ...
        uint32 w = (uint32(uint8(b[16])) << 24) | (uint32(uint8(b[17])) << 16) | (uint32(uint8(b[18])) << 8)
            | uint32(uint8(b[19]));
        uint32 h = (uint32(uint8(b[20])) << 24) | (uint32(uint8(b[21])) << 16) | (uint32(uint8(b[22])) << 8)
            | uint32(uint8(b[23]));
        assertEq(w, 4, "IHDR width");
        assertEq(h, 4, "IHDR height");
        assertEq(uint8(b[24]), 8, "bit depth");
        assertEq(uint8(b[25]), 6, "color type RGBA");
    }

    function test_ScaleFactorDoublesDims() public view {
        bytes memory b = enc.getImageBuffer(_img(), 2);
        uint32 w = (uint32(uint8(b[16])) << 24) | (uint32(uint8(b[17])) << 16) | (uint32(uint8(b[18])) << 8)
            | uint32(uint8(b[19]));
        assertEq(w, 8, "scaled width = 4*2");
    }

    function test_DataUriPrefix() public view {
        bytes memory uri = enc.getDataUri(_img(), 1);
        bytes memory prefix = "data:image/png;base64,";
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uri[i], prefix[i], "data URI prefix");
        }
    }

    // ---- golden regression pin --------------------------------------------
    // The exact keccak hash of the data URI of the 4x4 fixture. This pins the
    // output bytes. If this hash changes, the encoded bytes changed. Change the
    // pin only when that change is intended.
    bytes32 internal constant GOLDEN = 0x1f14a07cb61af2234af44237133b3b5289246d4778511661f848f8c3a1b4c331;

    function test_Golden() public view {
        bytes memory uri = enc.getDataUri(_img(), 1);
        assertEq(keccak256(uri), GOLDEN, "golden data URI drift");
    }

    function test_LogGolden() public {
        bytes memory uri = enc.getDataUri(_img(), 1);
        emit log_named_bytes32("golden keccak(getDataUri 4x4)", keccak256(uri));
        emit log_named_uint("golden uri length", uri.length);
        emit log_named_string("golden uri", string(uri));
    }

    // ---- gas ---------------------------------------------------------------
    function test_Gas_getDataUri() public {
        _gas(64);
        _gas(256);
        _gas(512);
    }

    function _gas(uint16 n) internal {
        Animation memory a = _square(n);
        uint256 g = gasleft();
        bytes memory uri = enc.getDataUri(a, 1);
        g = g - gasleft();
        emit log_named_uint(
            string.concat(
                "getDataUri ", vm.toString(n), "x", vm.toString(n), " (uri ", vm.toString(uri.length), "B) gas"
            ),
            g
        );
    }
}
