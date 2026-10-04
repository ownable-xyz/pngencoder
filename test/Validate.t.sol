// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PNGEncoder.sol";

/// Input validation. A malformed animation must revert with a typed error. It
/// must not make a corrupt PNG or write past the end of a buffer. This file
/// pins each validation check.
contract ValidateTest is Test {
    PNGEncoder internal enc;

    function setUp() public {
        enc = new PNGEncoder();
    }

    function _still(uint16 w, uint16 h) internal pure returns (Animation memory a) {
        a.frameCount = 1;
        a.width = w;
        a.height = h;
        a.frames = new bytes[](1);
        a.frames[0] = new bytes(uint256(w) * h * 4);
    }

    // A well-formed APNG fixture with 2 frames. Each test makes one field
    // incorrect.
    function _apng() internal pure returns (Animation memory a) {
        uint16 w = 4;
        uint16 h = 4;
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
            a.frames[f] = new bytes(uint256(w) * h * 4);
            a.delays[f] = 10;
            a.widths[f] = w;
            a.heights[f] = h;
        }
    }

    // ---- dimensions ---------------------------------------------------------

    function test_Reverts_ZeroScale() public {
        Animation memory a = _still(4, 4);
        vm.expectRevert(PNGEncoder.InvalidDimensions.selector);
        enc.getImageBuffer(a, 0);
    }

    function test_Reverts_ZeroWidth() public {
        Animation memory a = _still(4, 4);
        a.width = 0;
        vm.expectRevert(PNGEncoder.InvalidDimensions.selector);
        enc.getImageBuffer(a, 1);
    }

    function test_Reverts_ScaledTooLarge() public {
        // 600 * 200 = 120,000 scaled pixels wide. This is more than the uint16
        // limit.
        Animation memory a = _still(600, 4);
        vm.expectRevert(PNGEncoder.ImageTooLarge.selector);
        enc.getImageBuffer(a, 200);
    }

    // ---- pixel-buffer size --------------------------------------------------

    function test_Reverts_LayerSizeMismatch() public {
        Animation memory a = _still(4, 4);
        a.frames[0] = new bytes(4 * 4 * 4 - 1);
        vm.expectRevert(PNGEncoder.LayerSizeMismatch.selector);
        enc.getImageBuffer(a, 1);
    }

    function test_Reverts_IndexedLayerSizeMismatch() public {
        // The pre-indexed path expects one byte for each pixel.
        Animation memory a = _still(4, 4); // wrong: 4 bytes per pixel
        uint32[] memory p = new uint32[](1);
        p[0] = 0x000000FF;
        vm.expectRevert(PNGEncoder.LayerSizeMismatch.selector);
        enc.getImageBufferIndexed(a, 1, p, false);
    }

    // ---- APNG frame geometry -------------------------------------------------

    function test_Reverts_Frame0NotCanvas() public {
        Animation memory a = _apng();
        a.widths[0] = 2; // frame 0 must cover the canvas exactly
        vm.expectRevert(PNGEncoder.InvalidFrame.selector);
        enc.getImageBuffer(a, 1);
    }

    function test_Reverts_FrameOutsideCanvas() public {
        Animation memory a = _apng();
        a.xOffsets[1] = 2; // 2 + 4 > 4: hangs off the canvas
        vm.expectRevert(PNGEncoder.InvalidFrame.selector);
        enc.getImageBuffer(a, 1);
    }

    function test_Reverts_MissingPerFrameArrays() public {
        Animation memory a = _apng();
        a.delays = new uint16[](0);
        vm.expectRevert(PNGEncoder.InvalidFrame.selector);
        enc.getImageBuffer(a, 1);
    }

    // ---- windowed API --------------------------------------------------------

    function test_Reverts_RaggedBand() public {
        bytes memory band = new bytes(4 * 4 + 1); // not a whole number of rows
        vm.expectRevert(PNGEncoder.LayerSizeMismatch.selector);
        enc.pngStreamBand(band, 4, 1, true, 1);
    }

    function test_Reverts_EmptyBand() public {
        vm.expectRevert(PNGEncoder.LayerSizeMismatch.selector);
        enc.pngStreamBandDeflate(new bytes(0), 4, 1, true, 1);
    }

    function test_Reverts_StreamHeaderZeroDims() public {
        vm.expectRevert(PNGEncoder.InvalidDimensions.selector);
        enc.pngStreamHeader(0, 4, 1, new uint32[](0));
    }

    // ---- sanity: valid input still encodes ------------------------------------

    function test_ValidInputsEncode() public view {
        enc.getImageBuffer(_still(4, 4), 2);
        enc.getImageBuffer(_apng(), 1);
    }
}
