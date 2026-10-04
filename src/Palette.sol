// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wattsy
//
//   █▀█ █▄░█ █▀▀
//   █▀▀ █░▀█ █░█   a fully on-chain
//   ▀░░ ▀░░▀ ▀▀▀   PNG / APNG encoder
//
//  ── Palette ── colour extraction and indexed packing, one byte per pixel

pragma solidity ^0.8.24;

/// @title  Palette
/// @author wattsy
/// @notice Extracts a shared colour palette from one or more RGBA layers, so an
///         image with few distinct colours can be stored one byte per pixel
///         (an indexed PNG) instead of four.
/// @dev    A single open-addressed hash table maps each 32-bit RGBA colour to a
///         palette index in one pass:
///
///             for each pixel colour c:
///                 slot = hash(c)                 (linear-probe on collision)
///                 if unseen  → assign next index, remember it
///                 index[pixel] = palette index of c
///
///         The table has room for far more than the 256-colour cap, so a probe
///         always finds an empty slot. Indices are emitted per layer, in pixel
///         order, ready to become the indexed pixel stream.
library Palette {
    /// @notice Maximum distinct colours an indexed PNG can hold (8-bit index).
    uint256 internal constant MAX_COLORS = 256;

    uint256 private constant HT_SIZE = 1024; // hash slots (power of two, > MAX_COLORS)
    uint256 private constant HT_MASK = HT_SIZE - 1;

    /// @notice Builds a shared palette across `layers` and per-layer index maps.
    /// @param  layers   Row-major RGBA8 pixel buffers (4 bytes per pixel).
    /// @return ok       True if the layers use at most {MAX_COLORS} colours.
    /// @return colors   Distinct colours as packed RGBA (`R<<24|G<<16|B<<8|A`),
    ///                  in first-seen order; empty when `ok` is false.
    /// @return idxMaps  One buffer per layer: a palette index (1 byte) per pixel;
    ///                  empty when `ok` is false.
    function extract(bytes[] memory layers)
        internal
        pure
        returns (bool ok, uint32[] memory colors, bytes[] memory idxMaps)
    {
        uint256 n = layers.length;
        colors = new uint32[](MAX_COLORS);
        idxMaps = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            idxMaps[i] = new bytes(layers[i].length / 4);
        }

        bytes memory table = new bytes(HT_SIZE * 32); // zero-filled slots

        uint256 count = 0;
        uint256 overflow = 0;
        assembly {
            let colp := add(colors, 0x20) // colors[] data
            let htp := add(table, 0x20) // hash slots (index+1, 0 = empty)
            let layersData := add(layers, 0x20)
            let idxData := add(idxMaps, 0x20)

            for { let li := 0 } lt(li, n) { li := add(li, 1) } {
                let layer := mload(add(layersData, mul(li, 0x20)))
                let src := add(layer, 0x20)
                let end := add(src, mul(div(mload(layer), 4), 4))
                let dst := add(mload(add(idxData, mul(li, 0x20))), 0x20)

                for {} lt(src, end) {
                    src := add(src, 4)
                    dst := add(dst, 1)
                } {
                    let c := shr(224, mload(src)) // RGBA in the low 32 bits
                    let h := and(shr(16, mul(c, 2654435761)), 1023) // & (HT_SIZE - 1)
                    for {} 1 {} {
                        let slotp := add(htp, mul(h, 0x20))
                        // slot packs the colour (low 32 bits) and index+1 (above),
                        // so a repeated colour (the common case) is matched from
                        // the slot alone, without a second read into colors[].
                        let slot := mload(slotp)
                        if iszero(slot) {
                            if eq(count, 256) {
                                // MAX_COLORS
                                overflow := 1
                                src := end // stop the pixel loop after this break
                                break
                            }
                            mstore(slotp, or(shl(32, add(count, 1)), c))
                            mstore(add(colp, mul(count, 0x20)), c)
                            mstore8(dst, count)
                            count := add(count, 1)
                            break
                        }
                        if eq(and(slot, 0xffffffff), c) {
                            mstore8(dst, sub(shr(32, slot), 1))
                            break
                        }
                        h := and(add(h, 1), 1023)
                    }
                }
                if overflow { break }
            }
        }

        if (overflow == 1) {
            return (false, new uint32[](0), new bytes[](0));
        }
        assembly {
            mstore(colors, count) // trim to the colours actually used
        }
        ok = true;
    }
}
