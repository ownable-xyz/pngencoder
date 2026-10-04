// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wattsy
//
//   █▀█ █▄░█ █▀▀
//   █▀▀ █░▀█ █░█   a fully on-chain
//   ▀░░ ▀░░▀ ▀▀▀   PNG / APNG encoder
//
//  ── Animation ── the input model: frames and per-frame timing

pragma solidity ^0.8.24;

/// @notice The full picture handed to the encoder.
/// @dev    Each frame is one row-major pixel buffer: RGBA8 (4 bytes per pixel)
///         on the truecolor paths, or one palette index per pixel (1 byte) on
///         the pre-indexed paths. The encoder never composites — one buffer per
///         frame is the whole input.
///
///         A single-frame `Animation` encodes to a still PNG (the per-frame
///         arrays may be left empty); `frameCount > 1` encodes to an animated
///         PNG (APNG), and the per-frame arrays are indexed in lockstep with
///         `frames`. Frame 0 must cover the canvas exactly (offset 0, canvas
///         width × height, as the APNG spec requires of the frame that shares
///         IDAT); later frames must sit inside the canvas.
///
///             Animation
///             ├─ width × height, frameCount
///             ├─ frames[]   each: one row-major pixel buffer
///             └─ per-frame: delays[], xOffsets[], yOffsets[], widths[], heights[]
///
///         `frameCount` is authoritative, not `frames.length`. The encoder reads
///         exactly `frameCount` frames and the first `frameCount` entries of each
///         per-frame array; those arrays must be at least that long (shorter
///         reverts `InvalidFrame`), and any trailing entries past `frameCount`
///         are ignored. The counts win — keep them in sync with the arrays.
///
/// @param  frameCount Number of frames (1 = still image); authoritative over
///                    `frames.length` (see above).
/// @param  width      Canvas width in pixels.
/// @param  height     Canvas height in pixels.
/// @param  frames     The frames, played in order; each one row-major pixel buffer.
/// @param  delays     Per-frame display time, in hundredths of a second.
/// @param  xOffsets   Per-frame x placement within the canvas.
/// @param  yOffsets   Per-frame y placement within the canvas.
/// @param  widths     Per-frame width.
/// @param  heights    Per-frame height.
struct Animation {
    uint16 frameCount;
    uint16 width;
    uint16 height;
    bytes[] frames;
    uint16[] delays;
    uint16[] xOffsets;
    uint16[] yOffsets;
    uint16[] widths;
    uint16[] heights;
}
