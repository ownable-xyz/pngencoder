// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PNGEncoder.sol";

/// Renders an **animated PNG** (APNG): a gold seam that moves across a dark
/// lacquer panel, in the style of kintsugi. The seam grows in each frame and
/// has a bright tip. Then the animation loops. The simulated EVM calculates and
/// encodes all of the image.
///   forge script script/Demo.s.sol
contract Demo is Script {
    uint256 constant W = 128;
    uint256 constant H = 128;
    uint256 constant F = 16; // frames

    function run() external {
        PNGEncoder enc = new PNGEncoder();

        // Control points for the centre line of the seam. There is one point
        // for each 8 px in x, thus 17 points across the 128-wide panel. _seamY
        // interpolates linearly between the points.
        int256[17] memory cp = [int256(64), 52, 44, 54, 72, 84, 76, 58, 40, 34, 48, 66, 82, 88, 74, 60, 64];

        Animation memory a;
        a.frameCount = uint16(F);
        a.width = uint16(W);
        a.height = uint16(H);
        a.frames = new bytes[](F);
        a.delays = new uint16[](F);
        a.xOffsets = new uint16[](F);
        a.yOffsets = new uint16[](F);
        a.widths = new uint16[](F);
        a.heights = new uint16[](F);

        for (uint256 f = 0; f < F; f++) {
            a.frames[f] = _frame(f, cp);
            a.delays[f] = 6; // 6/100 s per frame  (~16 fps, ~1s loop)
            a.widths[f] = uint16(W);
            a.heights[f] = uint16(H);
        }

        Encoding color = enc.resolveEncoding(a); // Indexed if <=256 colours, else TrueColor
        bytes memory png = enc.getImageBuffer(a, 1, Encoding.AutoDeflate);
        vm.writeFileBinary("demo/kintsugi.png", png);
        vm.writeFile("demo/kintsugi.uri.txt", string(enc.getDataUri(a, 1, Encoding.AutoDeflate)));

        console2.log("wrote demo/kintsugi.png (APNG)");
        console2.log("  frames  :", F);
        console2.log("  encoding:", color == Encoding.Indexed ? "indexed + deflate" : "truecolor + deflate");
        console2.log("  bytes   :", png.length);
    }

    // ------------------------------------------------------------------ render
    //
    // The palette is quantized. The full animation has only some tens of
    // different colours, so it encodes as an indexed PNG (~4x smaller). Each
    // pixel has one solid palette colour. There is no alpha blending for each
    // pixel, because blending makes an unlimited number of intermediate
    // colours:
    //
    //     background : 32 vertical lacquer shades
    //     seam       : 8 gold "glint" shades + 1 mid gold + 1 amber edge
    //     molten tip : 6 warm-white -> gold rings
    //
    function _frame(uint256 f, int256[17] memory cp) internal pure returns (bytes memory px) {
        px = new bytes(W * H * 4);

        // The dark lacquer background: a vertical gradient with 32 bands, from
        // top to bottom.
        for (uint256 y = 0; y < H; y++) {
            uint256 band = (y * 32) / H; // 0..31
            uint256 r = 30 - (18 * band) / 31;
            uint256 g = 26 - (16 * band) / 31;
            uint256 b = 34 - (18 * band) / 31;
            for (uint256 x = 0; x < W; x++) {
                _set(px, x, y, r, g, b);
            }
        }

        // Grow the seam from left to right. revealX advances by one fraction of
        // the panel in each frame.
        uint256 revealX = ((f + 1) * W) / F;
        if (revealX > W) revealX = W;

        for (uint256 x = 0; x < revealX; x++) {
            uint256 sy = _seamY(x, cp);
            uint256 level = ((x * 7 + f * 13) % 46) * 8 / 46; // gold glint, 0..7
            _stamp(px, x, sy, level);
        }

        // The bright tip at the front of the seam.
        if (revealX > 0) {
            _tip(px, revealX - 1, _seamY(revealX - 1, cp));
        }
    }

    function _seamY(uint256 x, int256[17] memory cp) internal pure returns (uint256) {
        uint256 i = x / 8;
        if (i >= 16) return uint256(cp[16]);
        uint256 local = x % 8;
        int256 y = cp[i] + ((cp[i + 1] - cp[i]) * int256(local)) / 8;
        return uint256(y);
    }

    // A small radial dab: a bright gold core (one of 8 glints), then mid gold,
    // then an amber edge.
    function _stamp(bytes memory px, uint256 cx, uint256 cy, uint256 level) internal pure {
        for (int256 dx = -3; dx <= 3; dx++) {
            for (int256 dy = -3; dy <= 3; dy++) {
                int256 d2 = dx * dx + dy * dy;
                if (d2 > 9) continue;
                if (d2 <= 1) {
                    _put(px, cx, cy, dx, dy, 255, 210 + 4 * level, 110 + 6 * level); // core glint
                } else if (d2 <= 4) {
                    _put(px, cx, cy, dx, dy, 214, 168, 74); // mid gold
                } else {
                    _put(px, cx, cy, dx, dy, 110, 76, 30); // amber edge
                }
            }
        }
    }

    // The bright tip: concentric solid rings, from bright warm white to gold.
    function _tip(bytes memory px, uint256 cx, uint256 cy) internal pure {
        for (int256 dx = -6; dx <= 6; dx++) {
            for (int256 dy = -6; dy <= 6; dy++) {
                int256 d2 = dx * dx + dy * dy;
                if (d2 > 36) continue;
                uint256 r;
                uint256 g;
                uint256 b;
                if (d2 <= 1) {
                    (r, g, b) = (255, 246, 214);
                } else if (d2 <= 4) {
                    (r, g, b) = (255, 238, 196);
                } else if (d2 <= 9) {
                    (r, g, b) = (255, 228, 164);
                } else if (d2 <= 16) {
                    (r, g, b) = (252, 212, 132);
                } else if (d2 <= 25) {
                    (r, g, b) = (232, 188, 104);
                } else {
                    (r, g, b) = (196, 156, 80);
                }
                _put(px, cx, cy, dx, dy, r, g, b);
            }
        }
    }

    // ------------------------------------------------------------------ pixels
    /// Writes a solid opaque pixel without a bounds check. The full-canvas
    /// background uses this function.
    function _set(bytes memory px, uint256 x, uint256 y, uint256 r, uint256 g, uint256 b) internal pure {
        uint256 o = (y * W + x) * 4;
        px[o] = bytes1(uint8(r));
        px[o + 1] = bytes1(uint8(g));
        px[o + 2] = bytes1(uint8(b));
        px[o + 3] = bytes1(uint8(255));
    }

    /// Writes a solid opaque pixel at (cx+dx, cy+dy), clipped to the canvas.
    function _put(bytes memory px, uint256 cx, uint256 cy, int256 dx, int256 dy, uint256 r, uint256 g, uint256 b)
        internal
        pure
    {
        int256 xi = int256(cx) + dx;
        int256 yi = int256(cy) + dy;
        if (xi < 0 || yi < 0 || uint256(xi) >= W || uint256(yi) >= H) return;
        _set(px, uint256(xi), uint256(yi), r, g, b);
    }
}
