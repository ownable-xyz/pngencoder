// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wattsy
//
//   █▀█ █▄░█ █▀▀
//   █▀▀ █░▀█ █░█   a fully on-chain
//   ▀░░ ▀░░▀ ▀▀▀   PNG / APNG encoder
//
//  ── Filter ── per-row PNG filtering (None/Sub/Up), smaller before it deflates

pragma solidity ^0.8.24;

/// @title  Filter
/// @author wattsy
/// @notice Applies PNG row filters (types None=0 / Sub=1 / Up=2, per the PNG
///         specification, ISO/IEC 15948) so the pixels compress better.
/// @dev    A filter replaces each byte with its difference from a neighbour, so
///         an axis-aligned gradient or a repeated row becomes a run of one
///         value that DEFLATE's run-length step then crushes:
///
///             None : x
///             Sub  : x - left       (turns a horizontal ramp into a run)
///             Up   : x - above      (turns a repeated row into a run of zeros)
///
///         Each row independently picks the filter that leaves the fewest
///         "run breaks" (adjacent differing bytes) and is rewritten in place
///         with that filter's byte prefix. Because the compressor is run-length
///         based, longest-runs is the right target, and `None` is tried first,
///         so filtering never loses to leaving the row unfiltered. Filtering is
///         only worthwhile ahead of compression, so it is applied on the DEFLATE
///         paths only.
///
///         The whole pass runs in assembly: one per-byte scoring loop over the
///         three candidates, then the winner is rewritten with word-wide
///         bytewise subtraction (no borrow crosses a byte lane, so 32 bytes
///         filter in a handful of ops).
library Filter {
    /// @notice Filters every row of `scan` in place, choosing the best filter.
    /// @param  scan     Scanlines, each `[filter byte][rowBytes of pixels]`.
    /// @param  rowBytes Pixel bytes per row (excludes the filter byte).
    /// @param  bpp      Bytes per pixel (the offset to the "left" neighbour).
    /// @param  restrictFirstRow When true the first row may use only None/Sub,
    ///         never Up. Set this when `scan` is a band whose row above lives in
    ///         a different call: the decoder un-filters continuously, so an `Up`
    ///         on the band's first row would resolve against the previous band's
    ///         last row (which this call never saw). None/Sub reference nothing
    ///         above, so they reconstruct correctly regardless of the split.
    function filterRows(bytes memory scan, uint256 rowBytes, uint256 bpp, bool restrictFirstRow) internal pure {
        if (rowBytes == 0) return;

        bytes memory prior = new bytes(rowBytes); // row above (originals); zero for row 0
        bytes memory stash = new bytes(rowBytes); // this row's originals, kept for the next row

        assembly {
            // d = per-byte (a - b) mod 256, no borrow crossing byte lanes:
            //     ((a | H) - (b & ~H)) ^ ((a ^ ~b) & H),  H = 0x80 per lane
            function bsub(a, b) -> d {
                let h := 0x8080808080808080808080808080808080808080808080808080808080808080
                d := xor(sub(or(a, h), and(b, not(h))), and(xor(a, not(b)), h))
            }

            // score all three filters in one sweep, then choose: None wins
            // ties, Sub beats None only strictly, Up (when allowed) beats both
            // only strictly
            function choose(rowp, pr, nb, bpp2, allowUp) -> best {
                let bn := 0
                let bs := 0
                let bu := 0
                {
                    let pNone := 0
                    let pSub := 0
                    let pUp := 0
                    for { let i := 0 } lt(i, nb) { i := add(i, 1) } {
                        let x := byte(0, mload(add(rowp, i)))
                        let left := 0
                        if iszero(lt(i, bpp2)) { left := byte(0, mload(add(rowp, sub(i, bpp2)))) }
                        let fSub := and(sub(x, left), 0xff)
                        let fUp := and(sub(x, byte(0, mload(add(pr, i)))), 0xff)
                        if i {
                            bn := add(bn, iszero(eq(x, pNone)))
                            bs := add(bs, iszero(eq(fSub, pSub)))
                            bu := add(bu, iszero(eq(fUp, pUp)))
                        }
                        pNone := x
                        pSub := fSub
                        pUp := fUp
                    }
                }
                best := 0
                if lt(bs, bn) {
                    best := 1
                    bn := bs
                }
                if and(allowUp, lt(bu, bn)) { best := 2 }
            }

            // Sub: x - left from the stashed originals; the first bpp bytes
            // keep x - 0 = x. Whole words first, then the tail per byte.
            function rewriteSub(rowp, st, nb, bpp2) {
                let i := bpp2
                for {} iszero(gt(add(i, 32), nb)) { i := add(i, 32) } {
                    mstore(add(rowp, i), bsub(mload(add(st, i)), mload(add(st, sub(i, bpp2)))))
                }
                for {} lt(i, nb) { i := add(i, 1) } {
                    mstore8(add(rowp, i), sub(byte(0, mload(add(st, i))), byte(0, mload(add(st, sub(i, bpp2))))))
                }
            }

            // Up: x - above, against the prior row's originals.
            function rewriteUp(rowp, st, pr, nb) {
                let i := 0
                for {} iszero(gt(add(i, 32), nb)) { i := add(i, 32) } {
                    mstore(add(rowp, i), bsub(mload(add(st, i)), mload(add(pr, i))))
                }
                for {} lt(i, nb) { i := add(i, 1) } {
                    mstore8(add(rowp, i), sub(byte(0, mload(add(st, i))), byte(0, mload(add(pr, i)))))
                }
            }

            let pr := add(prior, 0x20)
            let st := add(stash, 0x20)
            let rows := div(mload(scan), add(rowBytes, 1))
            let rowp := add(scan, 0x21) // first row's pixel bytes

            for { let y := 0 } lt(y, rows) { y := add(y, 1) } {
                let best := choose(rowp, pr, rowBytes, bpp, iszero(and(restrictFirstRow, iszero(y))))

                // stash the originals, then rewrite the row in place
                mstore8(sub(rowp, 1), best)
                mcopy(st, rowp, rowBytes)
                switch best
                case 1 { rewriteSub(rowp, st, rowBytes, bpp) }
                case 2 { rewriteUp(rowp, st, pr, rowBytes) }
                default {}

                // this row's originals become the next row's "above"
                let t := pr
                pr := st
                st := t
                rowp := add(rowp, add(rowBytes, 1))
            }
        }
    }
}
