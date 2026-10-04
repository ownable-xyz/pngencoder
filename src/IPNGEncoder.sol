// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wattsy
//
//   █▀█ █▄░█ █▀▀
//   █▀▀ █░▀█ █░█   a fully on-chain
//   ▀░░ ▀░░▀ ▀▀▀   PNG / APNG encoder
//
//  ── IPNGEncoder ── the encoder's full public surface, ERC-165 discoverable

pragma solidity ^0.8.24;

import "./Animation.sol";

/// @notice How pixels are represented, and whether they are compressed.
/// @dev    Colour: `TrueColor` stores RGBA (any colours, four bytes per pixel);
///         `Indexed` stores a palette plus one byte per pixel (needs <= 256
///         colours). Compression: the plain variants store the pixels
///         uncompressed (cheapest to encode); the `*Deflate` variants run full
///         DEFLATE — LZ77 matching plus fixed or per-block dynamic Huffman
///         codes, whichever is smaller (much smaller output, much more encode
///         gas); the `*RLE` variants run the cheap run-length tier — far less
///         encode gas than full DEFLATE and nearly as small on run-heavy
///         palette art. `Auto*` chooses Indexed when the image qualifies, else
///         TrueColor (`AutoRLE` falls back to *stored* TrueColor: the RLE tier
///         is indexed-only).
enum Encoding {
    TrueColor,
    Indexed,
    Auto,
    TrueColorDeflate,
    IndexedDeflate,
    AutoDeflate,
    IndexedRLE,
    AutoRLE
}

/// @title  IPNGEncoder
/// @author wattsy
/// @notice The full public surface of the on-chain PNG/APNG encoder: one-shot
///         encoding (RGBA or pre-indexed, stored/DEFLATE/RLE, raw bytes or
///         data URI), the windowed band-by-band API for images too large for
///         one call, and chunk patchers for APNG playback control.
/// @dev    `type(IPNGEncoder).interfaceId` is registered via ERC-165, so the
///         encoder is discoverable on-chain.
interface IPNGEncoder {
    // ---- one-shot encoding -------------------------------------------------

    function getDataUri(Animation memory animation, uint8 scaleFactor) external pure returns (bytes memory);
    function getDataUri(Animation memory animation, uint8 scaleFactor, Encoding encoding)
        external
        pure
        returns (bytes memory);
    function getImageBuffer(Animation memory animation, uint8 scaleFactor) external pure returns (bytes memory);
    function getImageBuffer(Animation memory animation, uint8 scaleFactor, Encoding encoding)
        external
        pure
        returns (bytes memory);

    // ---- still-image conveniences (no Animation boilerplate) ---------------

    function getDataUri(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor)
        external
        pure
        returns (bytes memory);
    function getDataUri(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor, Encoding encoding)
        external
        pure
        returns (bytes memory);
    function getImageBuffer(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor)
        external
        pure
        returns (bytes memory);
    function getImageBuffer(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor, Encoding encoding)
        external
        pure
        returns (bytes memory);

    // ---- pre-indexed input (caller-supplied palette) ------------------------

    function getImageBufferIndexed(Animation memory animation, uint8 scaleFactor, uint32[] memory palette, bool deflate)
        external
        pure
        returns (bytes memory);
    function getDataUriIndexed(Animation memory animation, uint8 scaleFactor, uint32[] memory palette, bool deflate)
        external
        pure
        returns (bytes memory);
    function getImageBufferIndexedRLE(Animation memory animation, uint8 scaleFactor, uint32[] memory palette)
        external
        pure
        returns (bytes memory);
    function getDataUriIndexedRLE(Animation memory animation, uint8 scaleFactor, uint32[] memory palette)
        external
        pure
        returns (bytes memory);

    function resolveEncoding(Animation memory animation) external pure returns (Encoding);

    // ---- string-returning URI twins (for tokenURI) -------------------------

    function getDataUriString(Animation memory animation, uint8 scaleFactor) external pure returns (string memory);
    function getDataUriString(Animation memory animation, uint8 scaleFactor, Encoding encoding)
        external
        pure
        returns (string memory);
    function getDataUriString(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor)
        external
        pure
        returns (string memory);
    function getDataUriString(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor, Encoding encoding)
        external
        pure
        returns (string memory);
    function getDataUriIndexedString(
        Animation memory animation,
        uint8 scaleFactor,
        uint32[] memory palette,
        bool deflate
    ) external pure returns (string memory);
    function getDataUriIndexedRLEString(Animation memory animation, uint8 scaleFactor, uint32[] memory palette)
        external
        pure
        returns (string memory);

    // ---- windowed encoding: build a large still one band per call ----------

    function pngStreamHeader(uint16 width, uint16 height, uint8 scaleFactor, uint32[] memory palette)
        external
        pure
        returns (bytes memory);
    function pngStreamPreamble(uint16 width, uint16 height, uint8 scaleFactor, uint32[] memory palette)
        external
        pure
        returns (bytes memory);
    function pngStreamOpen() external pure returns (bytes memory);
    function pngStreamBand(bytes memory bandPixels, uint16 width, uint8 scaleFactor, bool isIndexed, uint32 adlerState)
        external
        pure
        returns (bytes memory idat, uint32 newAdler);
    function pngStreamBandDeflate(
        bytes memory bandPixels,
        uint16 width,
        uint8 scaleFactor,
        bool isIndexed,
        uint32 adlerState
    ) external pure returns (bytes memory idat, uint32 newAdler);
    function pngStreamTrailer(uint32 adlerState) external pure returns (bytes memory);
    function pngChunk(bytes4 tag, bytes memory data) external pure returns (bytes memory);

    // ---- chunk patchers: APNG playback control on a finished buffer --------

    function withLoopCount(bytes memory png, uint32 loops) external pure returns (bytes memory);
    function withFrameControl(bytes memory png, uint256 frameIndex, uint8 disposeOp, uint8 blendOp)
        external
        pure
        returns (bytes memory);
}
