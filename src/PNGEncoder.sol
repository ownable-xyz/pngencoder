// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wattsy
//
//   █▀█ █▄░█ █▀▀
//   █▀▀ █░▀█ █░█   a fully on-chain
//   ▀░░ ▀░░▀ ▀▀▀   PNG / APNG encoder
//
//  ── PNGEncoder ── the front door: raw RGBA in, a PNG (or APNG)
//  data-URI out, entirely inside a view call. No IPFS, no off-chain
//  renderer. The other contracts here are the machinery it drives:
//  Deflate, Filter, Palette, CRC32, Buffer.
//
//  Standards: PNG / APNG per the PNG specification (ISO/IEC 15948, plus the
//  APNG animation extension); zlib (RFC 1950) wrapping DEFLATE (RFC 1951), with
//  a standard CRC-32 per chunk and an adler-32 per zlib stream (RFC 1950); data
//  URIs are base64 (RFC 4648); the copy path uses MCOPY (EIP-5656).

pragma solidity ^0.8.24;

import "./Buffer.sol";
import "./CRC32.sol";
import "./Encoder.sol";
import "./Palette.sol";
import "./Deflate.sol";
import "./Filter.sol";
import "./IPNGEncoder.sol";
import "./Self.sol";

/// @title  PNGEncoder
/// @author wattsy
/// @notice Encodes raw RGBA pixels into a PNG, or an animated PNG (APNG),
///         on-chain, returned as a `data:image/png;base64,…` URI.
/// @dev    The pipeline, per frame:
///
///             RGBA pixels
///                │  nearest-neighbour upscale + a PNG filter byte per row
///                ▼
///             scanlines ──► zlib( stored DEFLATE ) ──► adler-32
///                                                          │
///                                                          ▼
///             ┌──────── PNG byte stream ──────────────────────────────┐
///             │ signature │ IHDR │ [ animation chunks ] │ IEND        │
///             └────────────────────────────┬──────────────────────────┘
///                                          │  base64
///                                          ▼
///                              data:image/png;base64,…
///
///         A still image is `signature · IHDR · IDAT · IEND`. An APNG inserts an
///         `acTL`, then per frame an `fcTL` plus pixel data (`IDAT` for the first
///         frame, `fdAT` for the rest). Every chunk carries a CRC-32.
///
///         The output is sized exactly up front (`calculateBufferSize`) and
///         streamed into a single {Buffer}, so encoding never reallocates.
contract PNGEncoder is Encoder, CRC32, IPNGEncoder {
    using Buffer for bytes;

    uint8 private constant CHUNK_HEADER_LENGTH = 4;
    uint8 private constant CHUNK_LENGTH_BYTES = 4;
    uint8 private constant CRC32_LENGTH = 4;

    /// @notice Thrown when an {Animation} has no frames.
    error FrameCountIsZero();

    /// @notice Thrown when `Encoding.Indexed` is forced but the image has more
    ///         than 256 colours.
    error NotIndexable();

    /// @notice Thrown when a caller-supplied palette is empty or exceeds 256.
    error PaletteTooLarge();

    /// @notice Thrown when `width`, `height`, or `scaleFactor` is zero.
    error InvalidDimensions();

    /// @notice Thrown when a scaled dimension exceeds 65,535 pixels (the
    ///         encoder's cap; far beyond any per-call gas budget anyway).
    error ImageTooLarge();

    /// @notice Thrown when an animation's frame geometry is inconsistent: a
    ///         per-frame array is shorter than `frameCount`, frame 0 does not
    ///         cover the canvas exactly (the APNG spec requires it), or a
    ///         frame's region falls outside the canvas.
    error InvalidFrame();

    /// @notice Thrown when a frame's pixel-buffer byte length is not exactly its
    ///         width × height × bytes-per-pixel.
    error LayerSizeMismatch();

    /// @dev Validates `animation` before anything is written: dimensions and
    ///      scale are nonzero, scaled dimensions fit uint16, every frame's pixel
    ///      buffer is exactly the right byte length, and (for an APNG) every
    ///      frame region sits inside the canvas with frame 0 covering it exactly.
    ///      `bpp` is 4 for RGBA input, 1 for palette-index input. Rejecting
    ///      malformed input here is what lets the unchecked hot paths below
    ///      assume well-formed geometry.
    function _validate(Animation memory animation, uint8 scaleFactor, uint256 bpp) private pure {
        if (animation.frameCount == 0) revert FrameCountIsZero();
        uint256 w = animation.width;
        uint256 h = animation.height;
        if (w == 0 || h == 0 || scaleFactor == 0) revert InvalidDimensions();
        if (w * scaleFactor > 0xFFFF || h * scaleFactor > 0xFFFF) revert ImageTooLarge();

        uint256 n = animation.frameCount;
        if (animation.frames.length < n) revert InvalidFrame();
        if (n > 1) {
            if (
                animation.delays.length < n || animation.widths.length < n || animation.heights.length < n
                    || animation.xOffsets.length < n || animation.yOffsets.length < n
            ) revert InvalidFrame();
            if (
                animation.widths[0] != w || animation.heights[0] != h || animation.xOffsets[0] != 0
                    || animation.yOffsets[0] != 0
            ) revert InvalidFrame();
        }
        for (uint256 i = 0; i < n; i++) {
            uint256 fw = w;
            uint256 fh = h;
            if (n > 1) {
                fw = animation.widths[i];
                fh = animation.heights[i];
                if (fw == 0 || fh == 0) revert InvalidFrame();
                if (animation.xOffsets[i] + fw > w || animation.yOffsets[i] + fh > h) revert InvalidFrame();
            }
            if (animation.frames[i].length != fw * fh * bpp) revert LayerSizeMismatch();
        }
    }

    /// @dev Validates one windowed band: nonzero geometry and a pixel buffer
    ///      that is a whole number of rows.
    function _validateBand(bytes memory bandPixels, uint16 width, uint8 scaleFactor, bool isIndexed) private pure {
        if (width == 0 || scaleFactor == 0) revert InvalidDimensions();
        if (uint256(width) * scaleFactor > 0xFFFF) revert ImageTooLarge();
        uint256 rowBytes = uint256(width) * (isIndexed ? 1 : 4);
        if (bandPixels.length == 0 || bandPixels.length % rowBytes != 0) revert LayerSizeMismatch();
    }

    /// @inheritdoc IERC165
    /// @dev The full {IPNGEncoder} surface is discoverable, alongside the
    ///      narrower {IAnimationEncoder} registered by {Encoder}.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IPNGEncoder).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev What the contract hands back when an unknown function is called
    ///      (riding out on the {Self.Describe} custom error — a fallback can't
    ///      return state): one line of prose, then its interface as canonical
    ///      ABI signatures, one per line. Machine-consumable — each signature
    ///      line hashes to its selector, so a caller can reconstruct the ABI
    ///      with no external docs. (wattsyart/self.)
    string private constant SELF = "pngencoder: fully on-chain PNG/APNG encoder; RGBA or palette indices in, data:image/png;base64 out, in a view call. Encoding enum: 0 TrueColor 1 Indexed 2 Auto 3 TrueColorDeflate 4 IndexedDeflate 5 AutoDeflate 6 IndexedRLE 7 AutoRLE. abi:\n"
        "getDataUri((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8)\n"
        "getDataUri((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8,uint8)\n"
        "getImageBuffer((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8)\n"
        "getImageBuffer((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8,uint8)\n"
        "getDataUri(bytes,uint16,uint16,uint8)\n" "getDataUri(bytes,uint16,uint16,uint8,uint8)\n"
        "getImageBuffer(bytes,uint16,uint16,uint8)\n" "getImageBuffer(bytes,uint16,uint16,uint8,uint8)\n"
        "getDataUriString((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8)\n"
        "getDataUriString((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8,uint8)\n"
        "getDataUriString(bytes,uint16,uint16,uint8)\n" "getDataUriString(bytes,uint16,uint16,uint8,uint8)\n"
        "getDataUriIndexedString((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8,uint32[],bool)\n"
        "getDataUriIndexedRLEString((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8,uint32[])\n"
        "getImageBufferIndexed((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8,uint32[],bool)\n"
        "getDataUriIndexed((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8,uint32[],bool)\n"
        "getImageBufferIndexedRLE((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8,uint32[])\n"
        "getDataUriIndexedRLE((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]),uint8,uint32[])\n"
        "resolveEncoding((uint16,uint16,uint16,bytes[],uint16[],uint16[],uint16[],uint16[],uint16[]))\n"
        "pngStreamHeader(uint16,uint16,uint8,uint32[])\n" "pngStreamPreamble(uint16,uint16,uint8,uint32[])\n"
        "pngStreamOpen()\n" "pngStreamBand(bytes,uint16,uint8,bool,uint32)\n"
        "pngStreamBandDeflate(bytes,uint16,uint8,bool,uint32)\n" "pngStreamTrailer(uint32)\n" "pngChunk(bytes4,bytes)\n"
        "withLoopCount(bytes,uint32)\n" "withFrameControl(bytes,uint256,uint8,uint8)\n" "crc32(bytes)\n"
        "crc32WithStart(uint32,bytes)\n" "crc32WithStart(uint32,bytes,bool)\n" "supportsInterface(bytes4)\n";

    /// @notice Call any unknown function and the contract answers with itself —
    ///         reverting with {Self.Describe}, whose payload is one line of
    ///         prose and then this contract's canonical ABI signatures, one per
    ///         line (each line keccaks to its selector). (wattsyart/self.)
    fallback() external {
        revert Self.Describe(bytes(SELF));
    }

    /// @inheritdoc IAnimationEncoder
    /// @dev Truecolor: the always-available path. For a smaller output on
    ///      limited-palette images, use the three-argument overload.
    function getDataUri(Animation memory animation, uint8 scaleFactor)
        external
        pure
        override(IAnimationEncoder, IPNGEncoder)
        returns (bytes memory uri)
    {
        return encodeDataUri(getImageBuffer(animation, scaleFactor));
    }

    /// @notice Encodes `animation` into a PNG data URI with the chosen encoding.
    /// @param  animation   The picture to encode.
    /// @param  scaleFactor Integer nearest-neighbour upscale (1 = original size).
    /// @param  encoding    {Encoding} representation to use.
    /// @return The PNG data URI.
    function getDataUri(Animation memory animation, uint8 scaleFactor, Encoding encoding)
        external
        pure
        returns (bytes memory)
    {
        return encodeDataUri(getImageBuffer(animation, scaleFactor, encoding));
    }

    // =============================================================
    // Still-image conveniences: one RGBA frame, no Animation boilerplate
    // =============================================================

    /// @dev The still image the convenience overloads wrap: one frame.
    function _still(bytes memory pixels, uint16 width, uint16 height) private pure returns (Animation memory a) {
        a.frameCount = 1;
        a.width = width;
        a.height = height;
        a.frames = new bytes[](1);
        a.frames[0] = pixels;
    }

    /// @notice Encodes one still RGBA image into a PNG data URI.
    /// @param  rgba        Row-major RGBA8 pixels, `width*height*4` bytes.
    /// @param  width       Width in pixels.
    /// @param  height      Height in pixels.
    /// @param  scaleFactor Integer nearest-neighbour upscale (1 = original size).
    function getDataUri(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor)
        external
        pure
        returns (bytes memory)
    {
        return encodeDataUri(getImageBuffer(_still(rgba, width, height), scaleFactor));
    }

    /// @notice {getDataUri} for one still RGBA image with the chosen encoding.
    function getDataUri(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor, Encoding encoding)
        external
        pure
        returns (bytes memory)
    {
        return encodeDataUri(getImageBuffer(_still(rgba, width, height), scaleFactor, encoding));
    }

    /// @notice Encodes one still RGBA image to raw PNG bytes.
    function getImageBuffer(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor)
        external
        pure
        returns (bytes memory)
    {
        return getImageBuffer(_still(rgba, width, height), scaleFactor);
    }

    /// @notice {getImageBuffer} for one still RGBA image with the chosen encoding.
    function getImageBuffer(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor, Encoding encoding)
        external
        pure
        returns (bytes memory)
    {
        return getImageBuffer(_still(rgba, width, height), scaleFactor, encoding);
    }

    /// @notice Encodes an already-indexed animation with a caller-supplied
    ///         palette: the cheapest indexed path, since it skips colour
    ///         extraction. Best when the palette is known up front (most
    ///         generative art).
    /// @dev    Each frame's pixel buffer holds one palette index per pixel (not
    ///         RGBA), row-major; every index must be `< palette.length`. Palette
    ///         entries are packed RGBA (`R<<24 | G<<16 | B<<8 | A`).
    /// @param  animation   The picture (index data in place of RGBA pixels).
    /// @param  scaleFactor Integer nearest-neighbour upscale (1 = original size).
    /// @param  palette     Up to 256 colours, packed RGBA.
    /// @param  deflate     Compress the pixels (true) or store them (false).
    /// @return The PNG (or APNG) byte stream.
    function getImageBufferIndexed(Animation memory animation, uint8 scaleFactor, uint32[] memory palette, bool deflate)
        public
        pure
        returns (bytes memory)
    {
        return _indexed(animation, scaleFactor, palette, deflate ? MODE_DEFLATE : MODE_STORED);
    }

    /// @notice Indexed with the cheap run-length DEFLATE path ({Deflate.compressRLE}):
    ///         far less encode gas than the full compressor and nearly as small on
    ///         run-heavy palette art, so it fits large or animated images into a
    ///         view call where the full DEFLATE path would not.
    function getImageBufferIndexedRLE(Animation memory animation, uint8 scaleFactor, uint32[] memory palette)
        public
        pure
        returns (bytes memory)
    {
        return _indexed(animation, scaleFactor, palette, MODE_RLE);
    }

    uint8 private constant MODE_STORED = 0;
    uint8 private constant MODE_DEFLATE = 1;
    uint8 private constant MODE_RLE = 2;

    function _indexed(Animation memory animation, uint8 scaleFactor, uint32[] memory palette, uint8 mode)
        private
        pure
        returns (bytes memory)
    {
        _validate(animation, scaleFactor, 1); // 1 byte per pixel: palette indices
        if (palette.length == 0 || palette.length > Palette.MAX_COLORS) revert PaletteTooLarge();
        return encodeIndexed(animation, scaleFactor, palette, animation.frames, mode);
    }

    /// @notice {getImageBufferIndexed} wrapped as a `data:image/png;base64,…` URI.
    function getDataUriIndexed(Animation memory animation, uint8 scaleFactor, uint32[] memory palette, bool deflate)
        external
        pure
        returns (bytes memory)
    {
        return encodeDataUri(getImageBufferIndexed(animation, scaleFactor, palette, deflate));
    }

    /// @notice {getImageBufferIndexedRLE} wrapped as a `data:image/png;base64,…` URI.
    function getDataUriIndexedRLE(Animation memory animation, uint8 scaleFactor, uint32[] memory palette)
        external
        pure
        returns (bytes memory)
    {
        return encodeDataUri(getImageBufferIndexedRLE(animation, scaleFactor, palette));
    }

    // =============================================================
    // String-returning URI twins: same bytes, `string` for tokenURI
    // =============================================================
    //
    // Every `getDataUri*` returns `bytes` — the encoder's native buffer type —
    // but ERC-721/1155 `tokenURI` must return `string`. Each twin is a pure
    // `string(...)` reinterpret over the byte form (no copy, identical gas), so
    // a metadata contract returns the URI with no cast of its own. Mirroring all
    // six now, before the interface calcifies, keeps the cast out of every
    // integrator's code for good.

    /// @notice {getDataUri} as a `string` (for direct `tokenURI` return).
    function getDataUriString(Animation memory animation, uint8 scaleFactor) external pure returns (string memory) {
        return string(encodeDataUri(getImageBuffer(animation, scaleFactor)));
    }

    /// @notice {getDataUri} (chosen encoding) as a `string`.
    function getDataUriString(Animation memory animation, uint8 scaleFactor, Encoding encoding)
        external
        pure
        returns (string memory)
    {
        return string(encodeDataUri(getImageBuffer(animation, scaleFactor, encoding)));
    }

    /// @notice Still-image {getDataUri} as a `string`.
    function getDataUriString(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor)
        external
        pure
        returns (string memory)
    {
        return string(encodeDataUri(getImageBuffer(_still(rgba, width, height), scaleFactor)));
    }

    /// @notice Still-image {getDataUri} (chosen encoding) as a `string`.
    function getDataUriString(bytes memory rgba, uint16 width, uint16 height, uint8 scaleFactor, Encoding encoding)
        external
        pure
        returns (string memory)
    {
        return string(encodeDataUri(getImageBuffer(_still(rgba, width, height), scaleFactor, encoding)));
    }

    /// @notice {getDataUriIndexed} as a `string`.
    function getDataUriIndexedString(
        Animation memory animation,
        uint8 scaleFactor,
        uint32[] memory palette,
        bool deflate
    ) external pure returns (string memory) {
        return string(encodeDataUri(getImageBufferIndexed(animation, scaleFactor, palette, deflate)));
    }

    /// @notice {getDataUriIndexedRLE} as a `string`.
    function getDataUriIndexedRLEString(Animation memory animation, uint8 scaleFactor, uint32[] memory palette)
        external
        pure
        returns (string memory)
    {
        return string(encodeDataUri(getImageBufferIndexedRLE(animation, scaleFactor, palette)));
    }

    /// @notice Reports which encoding {Encoding.Auto} (or a forced `Indexed`)
    ///         would actually use for `animation`: `Indexed` if it has at most
    ///         256 colours across its frames, else `TrueColor`.
    /// @param  animation The picture to inspect.
    /// @return The encoding that would be applied.
    function resolveEncoding(Animation memory animation) public pure returns (Encoding) {
        (bool ok,,) = Palette.extract(animation.frames);
        if (ok) return Encoding.Indexed;
        return Encoding.TrueColor;
    }

    // =============================================================
    // PNG
    // =============================================================

    bytes private constant PNG_HEADER = hex"89504E470D0A1A0A";
    uint8 private constant PNG_HEADER_LENGTH = 8;

    /// @notice Encodes `animation` to raw PNG bytes (no data-URI wrapper).
    /// @param  animation   The picture to encode.
    /// @param  scaleFactor Integer nearest-neighbour upscale (1 = original size).
    /// @return buffer      The PNG (or APNG) byte stream.
    function getImageBuffer(Animation memory animation, uint8 scaleFactor) public pure returns (bytes memory buffer) {
        _validate(animation, scaleFactor, 4);

        uint256 size = calculateBufferSize(animation.width, animation.height, animation.frameCount, scaleFactor);

        // +32 slack: the in-place scaler's word stores may spill past the data
        buffer = Buffer.allocate(size + 32);

        buffer.append(PNG_HEADER);

        writeIHDR(buffer, animation, scaleFactor);

        if (animation.frameCount > 1) {
            writeACTL(buffer, animation);
            uint32 sequenceNumber = 0;
            for (uint256 i; i < animation.frameCount; i++) {
                writeFCTL(buffer, animation, i, sequenceNumber++, scaleFactor);
                if (i == 0) {
                    writeIDAT(buffer, animation, scaleFactor);
                } else {
                    writeFDAT(buffer, animation, i, sequenceNumber++, scaleFactor);
                }
            }
        } else {
            writeIDAT(buffer, animation, scaleFactor);
        }

        writeIEND(buffer);
    }

    /// @notice Encodes `animation` to raw PNG bytes with the chosen encoding.
    /// @param  animation   The picture to encode.
    /// @param  scaleFactor Integer nearest-neighbour upscale (1 = original size).
    /// @param  encoding    {Encoding} representation to use. `Indexed` reverts
    ///                     with {NotIndexable} if the image does not qualify;
    ///                     `Auto` falls back to `TrueColor` instead.
    /// @return The PNG (or APNG) byte stream.
    function getImageBuffer(Animation memory animation, uint8 scaleFactor, Encoding encoding)
        public
        pure
        returns (bytes memory)
    {
        _validate(animation, scaleFactor, 4);
        if (encoding == Encoding.TrueColor) return getImageBuffer(animation, scaleFactor);
        if (encoding == Encoding.TrueColorDeflate) return encodeTrueColorDeflate(animation, scaleFactor);

        uint8 mode = MODE_STORED;
        if (encoding == Encoding.IndexedDeflate || encoding == Encoding.AutoDeflate) mode = MODE_DEFLATE;
        else if (encoding == Encoding.IndexedRLE || encoding == Encoding.AutoRLE) mode = MODE_RLE;

        (bool ok, uint32[] memory colors, bytes[] memory idxMaps) = Palette.extract(animation.frames);
        if (ok) return encodeIndexed(animation, scaleFactor, colors, idxMaps, mode);

        if (encoding == Encoding.Indexed || encoding == Encoding.IndexedDeflate || encoding == Encoding.IndexedRLE) {
            revert NotIndexable();
        }
        // Auto / AutoDeflate / AutoRLE: fall back to truecolor (stored for
        // AutoRLE — the run-length tier is indexed-only)
        return
            mode == MODE_DEFLATE
                ? encodeTrueColorDeflate(animation, scaleFactor)
                : getImageBuffer(animation, scaleFactor);
    }

    // =============================================================
    // IHDR
    // =============================================================

    bytes private constant IHDR_HEADER = hex"49484452";
    uint8 private constant IHDR_CHUNK_LENGTH = 13;

    function writeIHDR(bytes memory buffer, Animation memory animation, uint8 scaleFactor) private pure {
        bytes memory ihdr = writeIHDRChunk(animation.width, animation.height, scaleFactor);
        buffer.appendUint32(IHDR_CHUNK_LENGTH);
        buffer.append(ihdr);
        buffer.appendUint32(crc32(ihdr));
    }

    function writeIHDRChunk(uint32 width, uint32 height, uint8 scaleFactor) private pure returns (bytes memory ihdr) {
        ihdr = Buffer.allocate(CHUNK_HEADER_LENGTH + IHDR_CHUNK_LENGTH);
        ihdr.append(IHDR_HEADER);
        ihdr.appendUint32(width * scaleFactor);
        ihdr.appendUint32(height * scaleFactor);
        ihdr.appendUint8(8); // bit depth
        ihdr.appendUint8(6); // color type (RGBA)
        ihdr.appendUint8(0); // compression (DEFLATE)
        ihdr.appendUint8(0); // filter (ADAPTIVE)
        ihdr.appendUint8(0); // interlace (NONE)
    }

    // =============================================================
    // IDAT
    // =============================================================

    bytes private constant IDAT_HEADER = hex"49444154";
    uint32 private constant IDAT_CRC32 = 0xca50f9e1;

    /// @dev CRC-32 of `buffer[from..length)`, continued from `state` and
    ///      finalized — checksums a just-written chunk region in place.
    function _crc32Slice(uint32 state, bytes memory buffer, uint256 from) private pure returns (uint32) {
        uint256 len = buffer.length - from;
        uint256 ptr;
        assembly {
            ptr := add(add(buffer, 0x20), from)
        }
        return _crc32Ptr(state, ptr, len, _crcTable()) ^ 0xFFFFFFFF;
    }

    /// @dev Appends an IDAT chunk whose payload is the stored-zlib encoding of
    ///      `src`'s scaled scanlines, built in place (see {_appendZlibStored}).
    function _idatStored(
        bytes memory buffer,
        bytes memory src,
        uint256 bytesPerScanline,
        uint8 scaleFactor,
        uint256 scaledLength,
        bool isIndexed
    ) private pure {
        buffer.appendUint32(uint32(_zlibStoredSize(scaledLength)));
        buffer.append(IDAT_HEADER);
        uint256 start = buffer.length;
        _appendZlibStored(buffer, src, bytesPerScanline, scaleFactor, scaledLength, isIndexed);
        buffer.appendUint32(_crc32Slice(IDAT_CRC32, buffer, start));
    }

    function writeIDAT(bytes memory buffer, Animation memory animation, uint8 scaleFactor) private pure {
        _idatStored(
            buffer,
            animation.frames[0],
            uint256(4) * animation.width,
            scaleFactor,
            _scaledSize(animation.width, animation.height, 4, scaleFactor),
            false
        );
    }

    // =============================================================
    // acTL
    // =============================================================

    bytes private constant ACTL_HEADER = hex"6163544C";
    uint8 private constant ACTL_CHUNK_LENGTH = 8;

    function writeACTL(bytes memory buffer, Animation memory animation) private pure {
        bytes memory actl = writeACTLChunk(
            animation.frameCount,
            0 /* infinite loop */
        );
        buffer.appendUint32(ACTL_CHUNK_LENGTH);
        buffer.append(actl);
        buffer.appendUint32(crc32(actl));
    }

    function writeACTLChunk(uint32 frameCount, uint32 loopCount) private pure returns (bytes memory actl) {
        actl = Buffer.allocate(CHUNK_HEADER_LENGTH + ACTL_CHUNK_LENGTH);
        actl.append(ACTL_HEADER);
        actl.appendUint32(frameCount);
        actl.appendUint32(loopCount);
    }

    // =============================================================
    // fcTL
    // =============================================================

    bytes private constant FCTL_HEADER = hex"6663544C";
    uint8 private constant FCTL_CHUNK_LENGTH = 26;

    function writeFCTL(
        bytes memory buffer,
        Animation memory animation,
        uint256 frameIndex,
        uint32 sequenceNumber,
        uint8 scaleFactor
    ) private pure {
        bytes memory fctl = writeFCTLChunk(animation, frameIndex, sequenceNumber, scaleFactor);
        buffer.appendUint32(FCTL_CHUNK_LENGTH);
        buffer.append(fctl);
        buffer.appendUint32(crc32(fctl));
    }

    function writeFCTLChunk(Animation memory animation, uint256 frameIndex, uint32 sequenceNumber, uint8 scaleFactor)
        private
        pure
        returns (bytes memory fcTL)
    {
        fcTL = Buffer.allocate(CHUNK_HEADER_LENGTH + FCTL_CHUNK_LENGTH);
        fcTL.append(FCTL_HEADER);
        fcTL.appendUint32(sequenceNumber);
        fcTL.appendUint32(animation.widths[frameIndex] * scaleFactor);
        fcTL.appendUint32(animation.heights[frameIndex] * scaleFactor);
        fcTL.appendUint32(animation.xOffsets[frameIndex] * scaleFactor);
        fcTL.appendUint32(animation.yOffsets[frameIndex] * scaleFactor);
        fcTL.appendUint16(animation.delays[frameIndex]); // delay numerator
        fcTL.appendUint16(100); // delay denominator
        fcTL.appendUint8(0); // APNG_DISPOSE_OP_NONE
        fcTL.appendUint8(1); // APNG_BLEND_OP_OVER
    }

    // =============================================================
    // fdAT
    // =============================================================

    bytes private constant FDAT_HEADER = hex"66644154";
    uint32 private constant FDAT_CRC32 = 0x0a4c0069;

    /// @dev Appends an fdAT chunk (sequence number + stored-zlib payload),
    ///      built in place like {_idatStored}; the CRC folds the sequence
    ///      number and payload in one pass over the buffer slice.
    function _fdatStored(
        bytes memory buffer,
        bytes memory src,
        uint256 bytesPerScanline,
        uint8 scaleFactor,
        uint256 scaledLength,
        bool isIndexed,
        uint32 sequenceNumber
    ) private pure {
        buffer.appendUint32(
            uint32(_zlibStoredSize(scaledLength)) + 4 /* sequenceNumber */
        );
        buffer.append(FDAT_HEADER);
        uint256 start = buffer.length;
        buffer.appendUint32(sequenceNumber);
        _appendZlibStored(buffer, src, bytesPerScanline, scaleFactor, scaledLength, isIndexed);
        buffer.appendUint32(_crc32Slice(FDAT_CRC32, buffer, start));
    }

    function writeFDAT(
        bytes memory buffer,
        Animation memory animation,
        uint256 frameIndex,
        uint32 sequenceNumber,
        uint8 scaleFactor
    ) private pure {
        _fdatStored(
            buffer,
            animation.frames[frameIndex],
            uint256(4) * animation.widths[frameIndex],
            scaleFactor,
            _scaledSize(animation.widths[frameIndex], animation.heights[frameIndex], 4, scaleFactor),
            false,
            sequenceNumber
        );
    }

    // =============================================================
    // IEND
    // =============================================================

    bytes private constant IEND_HEADER = hex"49454E44";
    uint32 private constant IEND_CRC32 = 0xAE426082;

    function writeIEND(bytes memory buffer) private pure {
        buffer.appendUint32(0);
        buffer.append(IEND_HEADER);
        buffer.appendUint32(IEND_CRC32);
    }

    // =============================================================
    // DEFLATE
    // =============================================================

    uint32 public constant ZLIB_HEADER_LENGTH = 2;
    uint32 public constant DEFLATE_BLOCK_LENGTH = 5;
    uint32 public constant ADLER_CHECKSUM_LENGTH = 4;
    uint32 public constant DEFLATE_MAX_BLOCK_SIZE = 0xFFFF;

    /// @dev Scanline bytes after scaling: `height*s` rows of a filter byte plus
    ///      `width*bpp*s` pixel bytes.
    function _scaledSize(uint256 width, uint256 height, uint256 bpp, uint8 scaleFactor) private pure returns (uint256) {
        return (height * scaleFactor) * (1 + width * bpp * scaleFactor);
    }

    /// @dev Size of the zlib stream that stores `scanlineLength` bytes.
    function _zlibStoredSize(uint256 scanlineLength) private pure returns (uint256) {
        uint256 numBlocks = (scanlineLength + DEFLATE_MAX_BLOCK_SIZE - 1) / DEFLATE_MAX_BLOCK_SIZE;
        return ZLIB_HEADER_LENGTH + (DEFLATE_BLOCK_LENGTH * numBlocks) + scanlineLength + ADLER_CHECKSUM_LENGTH;
    }

    /// @dev Appends a zlib stream of stored (uncompressed) DEFLATE blocks
    ///      holding the scaled scanlines of `src`, built **in place**: the
    ///      pixels scale directly into the output buffer shifted right by the
    ///      room the block headers need, the adler folds over them there, and
    ///      each block then compacts left behind its 5-byte header. Every
    ///      destination is at or left of its source and MCOPY is overlap-safe,
    ///      so no intermediate buffer ever exists — the EVM never frees memory,
    ///      which makes high-water allocation the quadratic cost driver on
    ///      large images.
    function _appendZlibStored(
        bytes memory buffer,
        bytes memory src,
        uint256 bytesPerScanline,
        uint8 scaleFactor,
        uint256 scaledLength,
        bool isIndexed
    ) private pure {
        // zlib stream header (RFC 1950): CM=8, CINFO=7 — a 32K window is
        // declared, though stored blocks use none
        buffer.appendUint8(0x78); // CMF
        buffer.appendUint8(0x9C); // FLG

        uint256 shift;
        uint256 scaledPtr;
        {
            uint256 numBlocks = (scaledLength + DEFLATE_MAX_BLOCK_SIZE - 1) / DEFLATE_MAX_BLOCK_SIZE;
            shift = DEFLATE_BLOCK_LENGTH * numBlocks;
            assembly {
                scaledPtr := add(add(add(buffer, 0x20), mload(buffer)), shift)
            }
        }
        if (isIndexed) _scaleIndexedTo(scaledPtr, src, bytesPerScanline, scaleFactor);
        else _scaleTo(scaledPtr, src, bytesPerScanline, scaleFactor);
        uint32 adler = _adler32Ptr(1, scaledPtr, scaledLength);

        assembly {
            let cursor := add(add(buffer, 0x20), mload(buffer))
            let srcp := add(cursor, shift)
            let remaining := scaledLength
            for {} remaining {} {
                let blockLen := remaining
                if gt(blockLen, 0xFFFF) { blockLen := 0xFFFF }
                remaining := sub(remaining, blockLen)
                // BFINAL (last block only) | BTYPE=00 | LEN LE | NLEN LE
                mstore8(cursor, iszero(remaining))
                mstore8(add(cursor, 1), and(blockLen, 0xff))
                mstore8(add(cursor, 2), and(shr(8, blockLen), 0xff))
                mstore8(add(cursor, 3), and(not(blockLen), 0xff))
                mstore8(add(cursor, 4), and(shr(8, not(blockLen)), 0xff))
                cursor := add(cursor, 5)
                mcopy(cursor, srcp, blockLen) // dest <= src: compacts left
                cursor := add(cursor, blockLen)
                srcp := add(srcp, blockLen)
            }
            mstore(buffer, add(mload(buffer), add(shift, scaledLength)))
        }
        buffer.appendUint32(adler);
    }

    function scale(bytes memory rgba, uint256 scaledLength, uint256 bytesPerScanline, uint8 scaleFactor)
        private
        pure
        returns (bytes memory)
    {
        bytes memory scaled = new bytes(scaledLength);
        uint256 dst;
        assembly {
            dst := add(scaled, 0x20)
        }
        _scaleTo(dst, rgba, bytesPerScanline, scaleFactor);
        return scaled;
    }

    /// @dev Nearest-neighbour upscale of RGBA rows into filter-prefixed
    ///      scanlines at `dstPtr` (raw pointer form so the stored path can
    ///      scale straight into its final buffer). The per-pixel MSTORE writes
    ///      a full word and may spill up to 28 bytes past the region's end;
    ///      callers guarantee that much slack.
    function _scaleTo(uint256 dstPtr, bytes memory rgba, uint256 bytesPerScanline, uint8 scaleFactor) private pure {
        assembly {
            let src := add(rgba, 0x20)
            let dst := dstPtr
            let srcEnd := add(src, mload(rgba))
            let stride := add(1, mul(bytesPerScanline, scaleFactor)) // output row length

            for {} lt(src, srcEnd) { src := add(src, bytesPerScanline) } {
                let rowStart := dst
                mstore8(dst, 0x00) // filter (NONE)
                dst := add(dst, 1)
                switch scaleFactor
                case 1 {
                    // 1:1 row: a single MCOPY beats a per-pixel write loop
                    mcopy(dst, src, bytesPerScanline)
                    dst := add(dst, bytesPerScanline)
                }
                default {
                    // build one output row (each pixel repeated horizontally)...
                    let rowEnd := add(src, bytesPerScanline)
                    for { let j := src } lt(j, rowEnd) { j := add(j, 4) } {
                        let pixel := mload(j)
                        for { let k := 0 } lt(k, scaleFactor) { k := add(k, 1) } {
                            mstore(dst, pixel)
                            dst := add(dst, 4)
                        }
                    }
                    // ...then replicate the whole row (filter + pixels) vertically
                    for { let l := 1 } lt(l, scaleFactor) { l := add(l, 1) } {
                        mcopy(dst, rowStart, stride)
                        dst := add(dst, stride)
                    }
                }
            }
        }
    }

    function appendDeflateBlockHeader(bytes memory buffer, uint256 length, bool isFinal) private pure {
        // Format: BFINAL (1 bit) | BTYPE (2 bits) | LEN | NLEN
        buffer.appendUint8(isFinal ? 0x01 : 0x00);
        buffer.appendUint8(uint8(length & 0xFF));
        buffer.appendUint8(uint8((length >> 8) & 0xFF));
        buffer.appendUint8(uint8(~length & 0xFF));
        buffer.appendUint8(uint8((~length >> 8) & 0xFF));
    }

    // =============================================================
    // Adler32 — the zlib stream checksum (RFC 1950)
    // =============================================================

    uint32 private constant MOD_ADLER = 65521;

    function adler32(bytes memory buffer) private pure returns (uint32) {
        return adler32From(1, buffer);
    }

    /// @dev Continues an adler-32 from a packed `(s2 << 16) | s1` state, so a
    ///      windowed encode can fold each band and thread the checksum onward.
    ///
    ///      Whole words fold with lane arithmetic (~20 ops per 32 bytes instead
    ///      of 32 byte-extracts and 64 adds). For a word with bytes b_0 (most
    ///      significant) .. b_31:
    ///
    ///          s1' = s1 + Σ b_k               (S: the byte sum)
    ///          s2' = s2 + 32·s1 + Σ (32-k)·b_k (W: the weighted sum)
    ///
    ///      The word splits into four vectors of eight bytes in 32-bit lanes;
    ///      multiplying a lane vector by a constant holding that vector's
    ///      weights in reversed lane order makes the product's top lane the dot
    ///      product (the degree-7 convolution coefficient). Every partial
    ///      coefficient stays below 2^32 — max 8·255·32 per product, summed
    ///      over four products — so no carry ever crosses a lane. The running
    ///      sums stay exact in full words (s2 < 2^64 even for multi-MB
    ///      buffers), so the modulo is deferred to the very end.
    function adler32From(uint32 state, bytes memory buffer) private pure returns (uint32) {
        uint256 ptr;
        assembly {
            ptr := add(buffer, 0x20)
        }
        return _adler32Ptr(state, ptr, buffer.length);
    }

    /// @dev Raw-pointer form of {adler32From}, so a slice of a larger buffer
    ///      can be folded without copying it out.
    function _adler32Ptr(uint32 state, uint256 ptr, uint256 length) private pure returns (uint32) {
        uint32 s1 = uint32(state & 0xFFFF);
        uint32 s2 = uint32(state >> 16);

        assembly {
            let end := add(ptr, and(length, not(31)))
            for {} lt(ptr, end) { ptr := add(ptr, 0x20) } {
                let w := mload(ptr)
                // tk = bytes k, k+4, .., k+28 in lanes 7..0
                let t0 := and(w, 0x000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff)
                let t1 := and(shr(8, w), 0x000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff)
                let t2 := and(shr(16, w), 0x000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff)
                let t3 := and(shr(24, w), 0x000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff)
                // byte sum: top lane of (t0+t1+t2+t3) x all-ones
                let bsum :=
                    shr(
                        224,
                        mul(
                            add(add(t0, t1), add(t2, t3)),
                            0x0000000100000001000000010000000100000001000000010000000100000001
                        )
                    )
                // weighted sum: top lane of the four weighted products
                // (t0 carries b_3,b_7,..,b_31 -> weights 29,25,..,1 reversed)
                let wsum :=
                    shr(
                        224,
                        add(
                            add(
                                mul(t0, 0x0000000100000005000000090000000d0000001100000015000000190000001d),
                                mul(t1, 0x00000002000000060000000a0000000e00000012000000160000001a0000001e)
                            ),
                            add(
                                mul(t2, 0x00000003000000070000000b0000000f00000013000000170000001b0000001f),
                                mul(t3, 0x00000004000000080000000c0000001000000014000000180000001c00000020)
                            )
                        )
                    )
                s2 := add(s2, add(shl(5, s1), wsum))
                s1 := add(s1, bsum)
            }
            let rem := and(length, 31)
            if rem {
                let w := mload(ptr)
                for { let i := 0 } lt(i, rem) { i := add(i, 1) } {
                    s1 := add(s1, byte(i, w))
                    s2 := add(s2, s1)
                }
            }

            // reduce mod 65521 once, at the end (unconditional: a bare `mod`
            // is correct even when a sum lands exactly on the modulus)
            s1 := mod(s1, MOD_ADLER)
            s2 := mod(s2, MOD_ADLER)
        }
        return ((s2 << 16) | s1);
    }

    // =============================================================
    // Sizing
    // =============================================================

    function calculateBufferSize(uint16 width, uint16 height, uint16 frameCount, uint8 scaleFactor)
        private
        pure
        returns (uint256 size)
    {
        // PNG
        size = uint256(PNG_HEADER_LENGTH);

        // IHDR
        {
            size += CHUNK_LENGTH_BYTES;
            size += CHUNK_HEADER_LENGTH + IHDR_CHUNK_LENGTH;
            size += CRC32_LENGTH;
        }

        if (frameCount > 1) {
            // acTL
            size += CHUNK_LENGTH_BYTES;
            size += CHUNK_HEADER_LENGTH + ACTL_CHUNK_LENGTH;
            size += CRC32_LENGTH;

            // fcTL
            size += frameCount * CHUNK_LENGTH_BYTES;
            size += frameCount * (CHUNK_HEADER_LENGTH + FCTL_CHUNK_LENGTH);
            size += frameCount * CRC32_LENGTH;

            // IDAT/fdAT
            size += frameCount * calculateFrameSize(width, height, scaleFactor);
            size += frameCount * 4;
        } else {
            // IDAT
            size += calculateFrameSize(width, height, scaleFactor);
        }

        // IEND
        {
            size += CHUNK_LENGTH_BYTES;
            size += CHUNK_HEADER_LENGTH;
            size += CRC32_LENGTH;
        }
    }

    function calculateFrameSize(uint16 width, uint16 height, uint8 scaleFactor) private pure returns (uint256 size) {
        uint256 scaledWidth = uint256(width * scaleFactor);
        uint256 scaledHeight = uint256(height * scaleFactor);
        uint256 bytesPerScanlineScaled = uint256(4) * scaledWidth;
        uint256 scaledLength = bytesPerScanlineScaled * scaledHeight + scaledHeight;
        uint256 numBlocks = (scaledLength + DEFLATE_MAX_BLOCK_SIZE - 1) / DEFLATE_MAX_BLOCK_SIZE;
        uint256 deflateSize =
            ZLIB_HEADER_LENGTH + (DEFLATE_BLOCK_LENGTH * numBlocks) + scaledLength + ADLER_CHECKSUM_LENGTH;

        uint256 chunk = CHUNK_HEADER_LENGTH + deflateSize;
        size += CHUNK_LENGTH_BYTES;
        size += chunk;
        size += CRC32_LENGTH;
    }

    // =============================================================
    // DataURI
    // =============================================================

    bytes private constant PNG_URI_PREFIX = "data:image/png;base64,";

    /// @dev Wraps a finished PNG as a data URI **in place**: the base64 body
    ///      expands over the PNG buffer itself, last group first. The URI's
    ///      data begins 22 bytes (the prefix) before the PNG's, so group k
    ///      writes at byte 22+4k while its source sits at 22+3k — every write
    ///      lands strictly right of all still-unread source bytes (4k' >= 3k+3
    ///      for k' > k). The behind-reads below a group's 3 source bytes are
    ///      masked by the 6-bit lookups. Avoiding a second PNG-sized buffer
    ///      matters because EVM memory never frees: the URI would otherwise
    ///      raise the high-water mark by the whole PNG again.
    function encodeDataUri(bytes memory png) private pure returns (bytes memory uri) {
        uint256 pngLen = png.length;
        uint256 groups = (pngLen + 2) / 3;
        uint256 b64Len = 4 * groups;
        bytes memory prefix = PNG_URI_PREFIX;

        assembly {
            uri := sub(png, 22) // the URI claims the 22 bytes before the PNG data
            let u := add(uri, 0x20)
            let p := add(png, 0x20)

            // plant the prefix first: the group loop never writes below u+22,
            // and the materialized `prefix` sits past the PNG where the URI's
            // tail will land, so it must be consumed before the loop runs
            mcopy(u, add(prefix, 0x20), 22)

            // base64 character table in scratch (clobbers the free pointer,
            // which is rewritten below)
            mstore(0x1f, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef")
            mstore(0x3f, sub("ghijklmnopqrstuvwxyz0123456789-_", 0x0230)) // standard alphabet

            // walk both cursors down: src covers the group's 3 source bytes as
            // the low bytes of a behind-read word, ptr its 4 output characters
            let src := add(p, sub(mul(3, groups), 32))
            let ptr := add(u, add(22, mul(4, groups)))
            for { let base := add(u, 22) } gt(ptr, base) {} {
                let inp := mload(src)
                src := sub(src, 3)
                ptr := sub(ptr, 4)
                mstore8(ptr, mload(and(shr(18, inp), 0x3F)))
                mstore8(add(ptr, 1), mload(and(shr(12, inp), 0x3F)))
                mstore8(add(ptr, 2), mload(and(shr(6, inp), 0x3F)))
                mstore8(add(ptr, 3), mload(and(inp, 0x3F)))
            }

            // '=' padding over the final group's spare characters
            let endp := add(u, add(22, b64Len))
            let r := mod(pngLen, 3)
            if r {
                mstore8(sub(endp, 1), 0x3d)
                if eq(r, 1) { mstore8(sub(endp, 2), 0x3d) }
            }

            mstore(uri, add(22, b64Len))
            mstore(0x40, and(add(endp, 31), not(31))) // free memory resumes past the URI
        }
    }

    // =============================================================
    // Indexed colour (type 3): palette + one byte per pixel
    // =============================================================

    bytes private constant PLTE_HEADER = hex"504C5445"; // "PLTE"
    bytes private constant TRNS_HEADER = hex"74524E53"; // "tRNS"

    /// @dev Assembles an indexed PNG/APNG from a shared palette and per-frame
    ///      index maps: signature, IHDR (type 3), PLTE, optional tRNS, the
    ///      still/animation chunks, then IEND. Each frame's pixels are stored or
    ///      DEFLATE-compressed; sizes are learned from the finished frame
    ///      payloads, so nothing is over-allocated.
    function encodeIndexed(
        Animation memory animation,
        uint8 scaleFactor,
        uint32[] memory colors,
        bytes[] memory idxMaps,
        uint8 mode
    ) private pure returns (bytes memory buffer) {
        uint256 trnsLen = transparencyLength(colors);
        uint256 palette = CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + 3 * colors.length + CRC32_LENGTH;
        if (trnsLen > 0) palette += CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + trnsLen + CRC32_LENGTH;

        if (mode == MODE_STORED) {
            // Stored sizes are computable up front, so the frames build
            // straight into the final buffer — no per-frame payload buffers.
            buffer = Buffer.allocate(shellSize() + palette + framesSizeStored(animation, scaleFactor));
        } else {
            // Compressed sizes are learned from the finished frame payloads,
            // so nothing is over-allocated.
            bytes[] memory payloads = indexedPayloads(animation, scaleFactor, idxMaps, mode);
            buffer = Buffer.allocate(shellSize() + palette + framesSize(animation.frameCount, payloads));
            buffer.append(PNG_HEADER);
            writeIHDRIndexed(buffer, animation.width, animation.height, scaleFactor);
            writePLTE(buffer, colors);
            if (trnsLen > 0) writeTRNS(buffer, colors, trnsLen);
            writeFrames(buffer, animation, scaleFactor, payloads);
            writeIEND(buffer);
            return buffer;
        }

        buffer.append(PNG_HEADER);
        writeIHDRIndexed(buffer, animation.width, animation.height, scaleFactor);
        writePLTE(buffer, colors);
        if (trnsLen > 0) writeTRNS(buffer, colors, trnsLen);
        writeFramesStored(buffer, animation, scaleFactor, idxMaps);
        writeIEND(buffer);
    }

    /// @dev Per-frame indexed pixel payloads: replicate + filter the 1-byte
    ///      indices into scanlines, then store or DEFLATE them.
    function indexedPayloads(Animation memory animation, uint8 scaleFactor, bytes[] memory idxMaps, uint8 mode)
        private
        pure
        returns (bytes[] memory payloads)
    {
        uint256 frameCount = animation.frameCount;
        payloads = new bytes[](frameCount);
        for (uint256 i = 0; i < frameCount; i++) {
            uint256 fw = i == 0 ? animation.width : animation.widths[i];
            uint256 fh = i == 0 ? animation.height : animation.heights[i];
            bytes memory scanlines = scaleIndexed(idxMaps[i], fw, _scaledSize(fw, fh, 1, scaleFactor), scaleFactor);
            if (mode == MODE_DEFLATE) {
                Filter.filterRows(scanlines, fw * scaleFactor, 1, false); // 1 byte per pixel
                payloads[i] = zlibDeflate(scanlines);
            } else {
                payloads[i] = zlibRLE(scanlines); // no filter: constant rows are already runs
            }
        }
    }

    /// @dev Size of the animation chunks for the stored-mode indexed path,
    ///      where every frame's payload size is computable up front.
    function framesSizeStored(Animation memory animation, uint8 scaleFactor) private pure returns (uint256 size) {
        uint256 frameCount = animation.frameCount;
        if (frameCount > 1) size += CHUNK_LENGTH_BYTES + (CHUNK_HEADER_LENGTH + ACTL_CHUNK_LENGTH) + CRC32_LENGTH;
        for (uint256 i = 0; i < frameCount; i++) {
            if (frameCount > 1) size += CHUNK_LENGTH_BYTES + (CHUNK_HEADER_LENGTH + FCTL_CHUNK_LENGTH) + CRC32_LENGTH;
            uint256 fw = i == 0 ? animation.width : animation.widths[i];
            uint256 fh = i == 0 ? animation.height : animation.heights[i];
            size += CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + _zlibStoredSize(_scaledSize(fw, fh, 1, scaleFactor))
                + CRC32_LENGTH;
            if (frameCount > 1 && i > 0) size += 4; // fdAT sequence number
        }
        size += 32; // slack for the in-place scaler's word stores
    }

    /// @dev The stored-mode analogue of {writeFrames}: every frame's payload
    ///      builds in place via {_idatStored} / {_fdatStored}.
    function writeFramesStored(
        bytes memory buffer,
        Animation memory animation,
        uint8 scaleFactor,
        bytes[] memory idxMaps
    ) private pure {
        uint256 frameCount = animation.frameCount;
        if (frameCount > 1) {
            writeACTL(buffer, animation);
            uint32 sequenceNumber = 0;
            for (uint256 i = 0; i < frameCount; i++) {
                writeFCTL(buffer, animation, i, sequenceNumber++, scaleFactor);
                uint256 fw = i == 0 ? animation.width : animation.widths[i];
                uint256 fh = i == 0 ? animation.height : animation.heights[i];
                uint256 scaledLength = _scaledSize(fw, fh, 1, scaleFactor);
                if (i == 0) {
                    _idatStored(buffer, idxMaps[0], fw, scaleFactor, scaledLength, true);
                } else {
                    _fdatStored(buffer, idxMaps[i], fw, scaleFactor, scaledLength, true, sequenceNumber++);
                }
            }
        } else {
            _idatStored(
                buffer,
                idxMaps[0],
                animation.width,
                scaleFactor,
                _scaledSize(animation.width, animation.height, 1, scaleFactor),
                true
            );
        }
    }

    /// @dev How many leading palette entries a tRNS chunk must cover: one past
    ///      the last entry whose alpha is below 255 (0 means every entry is
    ///      opaque, so no tRNS chunk is needed).
    function transparencyLength(uint32[] memory colors) private pure returns (uint256 len) {
        for (uint256 i = 0; i < colors.length; i++) {
            if ((colors[i] & 0xFF) != 0xFF) len = i + 1;
        }
    }

    function writeIHDRIndexed(bytes memory buffer, uint32 width, uint32 height, uint8 scaleFactor) private pure {
        bytes memory ihdr = Buffer.allocate(CHUNK_HEADER_LENGTH + IHDR_CHUNK_LENGTH);
        ihdr.append(IHDR_HEADER);
        ihdr.appendUint32(width * scaleFactor);
        ihdr.appendUint32(height * scaleFactor);
        ihdr.appendUint8(8); // bit depth
        ihdr.appendUint8(3); // colour type (INDEXED)
        ihdr.appendUint8(0); // compression (DEFLATE)
        ihdr.appendUint8(0); // filter (ADAPTIVE)
        ihdr.appendUint8(0); // interlace (NONE)
        buffer.appendUint32(IHDR_CHUNK_LENGTH);
        buffer.append(ihdr);
        buffer.appendUint32(crc32(ihdr));
    }

    /// @dev PLTE carries the RGB of each palette entry (the alpha, if any, goes
    ///      in tRNS).
    function writePLTE(bytes memory buffer, uint32[] memory colors) private pure {
        uint256 count = colors.length;
        bytes memory plte = Buffer.allocate(CHUNK_HEADER_LENGTH + 3 * count);
        plte.append(PLTE_HEADER);
        for (uint256 i = 0; i < count; i++) {
            uint32 c = colors[i];
            plte.appendUint8(uint8(c >> 24)); // R
            plte.appendUint8(uint8(c >> 16)); // G
            plte.appendUint8(uint8(c >> 8)); // B
        }
        buffer.appendUint32(uint32(3 * count));
        buffer.append(plte);
        buffer.appendUint32(crc32(plte));
    }

    /// @dev tRNS carries the alpha of the leading palette entries; entries it
    ///      omits are opaque.
    function writeTRNS(bytes memory buffer, uint32[] memory colors, uint256 trnsLen) private pure {
        bytes memory trns = Buffer.allocate(CHUNK_HEADER_LENGTH + trnsLen);
        trns.append(TRNS_HEADER);
        for (uint256 i = 0; i < trnsLen; i++) {
            trns.appendUint8(uint8(colors[i])); // A
        }
        buffer.appendUint32(uint32(trnsLen));
        buffer.append(trns);
        buffer.appendUint32(crc32(trns));
    }

    /// @dev Appends an IDAT chunk wrapping a finished zlib payload.
    function _appendIDAT(bytes memory buffer, bytes memory payload) private pure {
        buffer.appendUint32(uint32(payload.length));
        buffer.append(IDAT_HEADER);
        buffer.append(payload);
        buffer.appendUint32(crc32WithStart(IDAT_CRC32, payload));
    }

    /// @dev Appends an fdAT chunk (sequence number + payload).
    function _appendFDAT(bytes memory buffer, bytes memory payload, uint32 sequenceNumber) private pure {
        buffer.appendUint32(
            uint32(payload.length) + 4 /* sequenceNumber */
        );
        buffer.append(FDAT_HEADER);
        buffer.appendUint32(sequenceNumber);
        buffer.append(payload);

        bytes memory sequenceNumberBuffer = new bytes(4);
        writeUInt32BE(sequenceNumberBuffer, 0, sequenceNumber);
        buffer.appendUint32(crc32WithStart(crc32WithStart(FDAT_CRC32, sequenceNumberBuffer, false), payload));
    }

    /// @dev Writes the animation chunks: acTL then per-frame fcTL + IDAT/fdAT
    ///      (a still image is just one IDAT). Shared by every encoding.
    function writeFrames(bytes memory buffer, Animation memory animation, uint8 scaleFactor, bytes[] memory payloads)
        private
        pure
    {
        uint256 frameCount = animation.frameCount;
        if (frameCount > 1) {
            writeACTL(buffer, animation);
            uint32 sequenceNumber = 0;
            for (uint256 i = 0; i < frameCount; i++) {
                writeFCTL(buffer, animation, i, sequenceNumber++, scaleFactor);
                if (i == 0) {
                    _appendIDAT(buffer, payloads[0]);
                } else {
                    _appendFDAT(buffer, payloads[i], sequenceNumber++);
                }
            }
        } else {
            _appendIDAT(buffer, payloads[0]);
        }
    }

    /// @dev Fixed shell size: signature + IHDR chunk + IEND chunk.
    function shellSize() private pure returns (uint256) {
        return uint256(PNG_HEADER_LENGTH)
            + (CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + IHDR_CHUNK_LENGTH + CRC32_LENGTH)
            + (CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + CRC32_LENGTH);
    }

    /// @dev Size of the animation chunks for the given finished frame payloads.
    function framesSize(uint256 frameCount, bytes[] memory payloads) private pure returns (uint256 size) {
        if (frameCount > 1) size += CHUNK_LENGTH_BYTES + (CHUNK_HEADER_LENGTH + ACTL_CHUNK_LENGTH) + CRC32_LENGTH;
        for (uint256 i = 0; i < frameCount; i++) {
            if (frameCount > 1) size += CHUNK_LENGTH_BYTES + (CHUNK_HEADER_LENGTH + FCTL_CHUNK_LENGTH) + CRC32_LENGTH;
            size += CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + payloads[i].length + CRC32_LENGTH;
            if (frameCount > 1 && i > 0) size += 4; // fdAT sequence number
        }
    }

    /// @dev Zlib-wraps `scanlines` with full DEFLATE ({Deflate.compress}: LZ77
    ///      plus fixed-or-dynamic Huffman) + an adler-32.
    function zlibDeflate(bytes memory scanlines) private pure returns (bytes memory out) {
        bytes memory compressed = Deflate.compress(scanlines);
        out = Buffer.allocate(ZLIB_HEADER_LENGTH + compressed.length + ADLER_CHECKSUM_LENGTH);
        out.appendUint8(0x78); // CMF
        out.appendUint8(0x9C); // FLG
        out.append(compressed);
        out.appendUint32(adler32(scanlines));
    }

    /// @dev zlib wrapper around the cheap run-length DEFLATE path.
    function zlibRLE(bytes memory scanlines) private pure returns (bytes memory out) {
        bytes memory compressed = Deflate.compressRLE(scanlines);
        out = Buffer.allocate(ZLIB_HEADER_LENGTH + compressed.length + ADLER_CHECKSUM_LENGTH);
        out.appendUint8(0x78); // CMF
        out.appendUint8(0x9C); // FLG
        out.append(compressed);
        out.appendUint32(adler32(scanlines));
    }

    /// @dev Truecolor path with DEFLATE compression.
    function encodeTrueColorDeflate(Animation memory animation, uint8 scaleFactor)
        private
        pure
        returns (bytes memory buffer)
    {
        bytes[] memory payloads = truecolorPayloads(animation, scaleFactor, animation.frames);

        buffer = Buffer.allocate(shellSize() + framesSize(animation.frameCount, payloads));
        buffer.append(PNG_HEADER);
        writeIHDR(buffer, animation, scaleFactor);
        writeFrames(buffer, animation, scaleFactor, payloads);
        writeIEND(buffer);
    }

    /// @dev Per-frame truecolor pixel payloads: upscale + filter the RGBA into
    ///      scanlines, then DEFLATE them.
    function truecolorPayloads(Animation memory animation, uint8 scaleFactor, bytes[] memory layers)
        private
        pure
        returns (bytes[] memory payloads)
    {
        uint256 frameCount = animation.frameCount;
        payloads = new bytes[](frameCount);
        for (uint256 i = 0; i < frameCount; i++) {
            uint256 fw = i == 0 ? animation.width : animation.widths[i];
            uint256 fh = i == 0 ? animation.height : animation.heights[i];
            uint256 scaledLength = (4 * fw * scaleFactor) * (fh * scaleFactor) + fh * scaleFactor;
            bytes memory scanlines = scale(layers[i], scaledLength, 4 * fw, scaleFactor);
            Filter.filterRows(scanlines, 4 * fw * scaleFactor, 4, false); // 4 bytes per pixel
            payloads[i] = zlibDeflate(scanlines);
        }
    }

    /// @dev Nearest-neighbour upscales the 1-byte index map, prefixing each
    ///      output row with a filter byte (NONE): the indexed analogue of
    ///      `scale`.
    function scaleIndexed(bytes memory idxMap, uint256 width, uint256 scaledLength, uint8 scaleFactor)
        private
        pure
        returns (bytes memory scaled)
    {
        scaled = new bytes(scaledLength);
        uint256 dst;
        assembly {
            dst := add(scaled, 0x20)
        }
        _scaleIndexedTo(dst, idxMap, width, scaleFactor);
    }

    /// @dev Raw-pointer form of {scaleIndexed} (all writes are MSTORE8/MCOPY,
    ///      so nothing spills past the region).
    function _scaleIndexedTo(uint256 dstPtr, bytes memory idxMap, uint256 width, uint8 scaleFactor) private pure {
        assembly {
            let src := add(idxMap, 0x20)
            let dst := dstPtr
            let srcEnd := add(src, mload(idxMap))
            let stride := add(1, mul(width, scaleFactor)) // output row length

            for {} lt(src, srcEnd) { src := add(src, width) } {
                let rowStart := dst
                mstore8(dst, 0x00) // filter (NONE)
                dst := add(dst, 1)
                switch scaleFactor
                case 1 {
                    // 1:1 row: a single MCOPY beats a per-index write loop
                    mcopy(dst, src, width)
                    dst := add(dst, width)
                }
                default {
                    // build one output row (each index repeated horizontally)...
                    let rowEnd := add(src, width)
                    for { let j := src } lt(j, rowEnd) { j := add(j, 1) } {
                        let idx := byte(0, mload(j))
                        for { let k := 0 } lt(k, scaleFactor) { k := add(k, 1) } {
                            mstore8(dst, idx)
                            dst := add(dst, 1)
                        }
                    }
                    // ...then replicate the whole row (filter + indices) vertically
                    for { let l := 1 } lt(l, scaleFactor) { l := add(l, 1) } {
                        mcopy(dst, rowStart, stride)
                        dst := add(dst, stride)
                    }
                }
            }
        }
    }

    // =============================================================
    // Windowed encoding: build a still PNG one row-band per call
    // =============================================================
    //
    // A caller (an on-chain renderer, or a client that has the pixels) assembles
    // a large image within per-`eth_call` gas budgets by chaining:
    //
    //     png   = pngStreamHeader(w, h, scale, palette)   // signature … zlib start
    //     adler = 1
    //     for each band of source rows, top to bottom:
    //         (idat, adler) = pngStreamBand(bandPixels, w, scale, isIndexed, adler)
    //         png = png · idat
    //     png = png · pngStreamTrailer(adler)              // final block · adler · IEND
    //
    // The pixels are stored uncompressed across many byte-aligned IDAT chunks
    // (each with its own CRC); the one zlib stream spans them (its 2-byte header
    // opens in the `header`, the adler-32 closes in the `trailer`), with the
    // adler threaded call to call. Concatenating the returned bytes yields a
    // valid PNG, so the client just joins them, no re-encode.

    /// @notice The bytes up to and including the zlib header: signature, IHDR,
    ///         (PLTE + optional tRNS for indexed) and the opening IDAT. Empty
    ///         palette ⇒ truecolor (type 6); otherwise indexed (type 3).
    /// @param  width       Canvas width (unscaled).
    /// @param  height      Canvas height (unscaled).
    /// @param  scaleFactor Integer nearest-neighbour upscale.
    /// @param  palette     Up to 256 packed-RGBA colours, or empty for truecolor.
    function pngStreamHeader(uint16 width, uint16 height, uint8 scaleFactor, uint32[] memory palette)
        external
        pure
        returns (bytes memory)
    {
        return bytes.concat(pngStreamPreamble(width, height, scaleFactor, palette), pngStreamOpen());
    }

    /// @notice The stream's opening chunks *without* the first IDAT: signature,
    ///         IHDR, and (when indexed) PLTE + optional tRNS. Splice ancillary
    ///         chunks built with {pngChunk} after this, then {pngStreamOpen}.
    function pngStreamPreamble(uint16 width, uint16 height, uint8 scaleFactor, uint32[] memory palette)
        public
        pure
        returns (bytes memory)
    {
        if (width == 0 || height == 0 || scaleFactor == 0) revert InvalidDimensions();
        if (uint256(width) * scaleFactor > 0xFFFF || uint256(height) * scaleFactor > 0xFFFF) revert ImageTooLarge();
        if (palette.length > Palette.MAX_COLORS) revert PaletteTooLarge();
        return _streamPreamble(width, height, scaleFactor, palette);
    }

    /// @notice Opens the single zlib stream in its own tiny IDAT (CMF=0x78,
    ///         FLG=0x9C). Everything after this must be IDAT chunks (the
    ///         bands), then the trailer — PNG requires IDATs to be consecutive.
    function pngStreamOpen() public pure returns (bytes memory) {
        return _dataIdat(hex"789C");
    }

    /// @notice Frames arbitrary bytes as a PNG chunk: length · tag · data · CRC.
    ///         For splicing ancillary chunks (tEXt, gAMA, pHYs, ...) into a
    ///         windowed stream between {pngStreamPreamble} and {pngStreamOpen}.
    /// @param  tag  The 4-byte chunk type (e.g. `"tEXt"`).
    /// @param  data The chunk's payload.
    function pngChunk(bytes4 tag, bytes memory data) public pure returns (bytes memory chunk) {
        chunk = Buffer.allocate(CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + data.length + CRC32_LENGTH);
        chunk.appendUint32(uint32(data.length));
        chunk.appendUint32(uint32(tag));
        chunk.append(data);
        chunk.appendUint32(_crc32Slice(0xFFFFFFFF, chunk, CHUNK_LENGTH_BYTES));
    }

    /// @dev Signature + IHDR (+ PLTE/tRNS when indexed).
    function _streamPreamble(uint16 width, uint16 height, uint8 scaleFactor, uint32[] memory palette)
        private
        pure
        returns (bytes memory header)
    {
        uint256 size = uint256(PNG_HEADER_LENGTH)
            + (CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + IHDR_CHUNK_LENGTH + CRC32_LENGTH);
        uint256 trnsLen = 0;
        if (palette.length > 0) {
            size += CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + 3 * palette.length + CRC32_LENGTH;
            trnsLen = transparencyLength(palette);
            if (trnsLen > 0) size += CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + trnsLen + CRC32_LENGTH;
        }
        header = Buffer.allocate(size);
        header.append(PNG_HEADER);
        _ihdrFramed(header, width, height, scaleFactor, palette.length == 0 ? 6 : 3);
        if (palette.length > 0) {
            writePLTE(header, palette);
            if (trnsLen > 0) writeTRNS(header, palette, trnsLen);
        }
    }

    /// @notice Encodes one band of source rows as stored DEFLATE inside its own
    ///         IDAT chunk, continuing the adler-32.
    /// @param  bandPixels  This band's pixels: `rowCount` rows of either `width`
    ///                     index bytes (indexed) or `width*4` RGBA bytes.
    /// @param  width       Canvas width (unscaled).
    /// @param  scaleFactor Integer nearest-neighbour upscale.
    /// @param  isIndexed   True for 1-byte indices, false for RGBA.
    /// @param  adlerState  Running adler state; pass 1 for the first band.
    /// @return idat        The IDAT chunk for this band.
    /// @return newAdler    The adler state to pass to the next band (or trailer).
    function pngStreamBand(bytes memory bandPixels, uint16 width, uint8 scaleFactor, bool isIndexed, uint32 adlerState)
        external
        pure
        returns (bytes memory idat, uint32 newAdler)
    {
        _validateBand(bandPixels, width, scaleFactor, isIndexed);
        bytes memory scanlines = _bandScanlines(bandPixels, width, scaleFactor, isIndexed);
        newAdler = adler32From(adlerState, scanlines);
        idat = _dataIdat(_storedBlocks(scanlines));
    }

    /// @notice Same windowed contract as `pngStreamBand`, but the band is
    ///         **compressed** (LZ77 + Huffman) rather than stored, so the finished
    ///         PNG is small. Each band is an independent DEFLATE fragment: its
    ///         match window is local to the band (no back-reference crosses the
    ///         call boundary) and it is sync-flushed to a byte boundary, so the
    ///         fragments concatenate into one stream that the trailer's final
    ///         block closes. The trade for band-independence is a small ratio cost
    ///         at the seams (no cross-band matches) versus a one-shot encode.
    /// @param  bandPixels  This band's pixels (see `pngStreamBand`).
    /// @param  width       Canvas width (unscaled).
    /// @param  scaleFactor Integer nearest-neighbour upscale.
    /// @param  isIndexed   True for 1-byte indices, false for RGBA.
    /// @param  adlerState  Running adler state; pass 1 for the first band.
    /// @return idat        The IDAT chunk for this band.
    /// @return newAdler    The adler state to pass to the next band (or trailer).
    function pngStreamBandDeflate(
        bytes memory bandPixels,
        uint16 width,
        uint8 scaleFactor,
        bool isIndexed,
        uint32 adlerState
    ) external pure returns (bytes memory idat, uint32 newAdler) {
        _validateBand(bandPixels, width, scaleFactor, isIndexed);
        bytes memory scanlines = _bandScanlines(bandPixels, width, scaleFactor, isIndexed);
        uint256 bpp = isIndexed ? 1 : 4;
        // Filter for compression, but the band's first row may not use Up: the
        // decoder un-filters continuously, so Up there would resolve against the
        // previous band's last row, which this call never saw.
        Filter.filterRows(scanlines, uint256(width) * scaleFactor * bpp, bpp, true);
        newAdler = adler32From(adlerState, scanlines); // over the filtered scanlines
        idat = _dataIdat(Deflate.compressBand(scanlines));
    }

    /// @dev Upscales + filter-prefixes a band of source rows into scanlines.
    function _bandScanlines(bytes memory bandPixels, uint16 width, uint8 scaleFactor, bool isIndexed)
        private
        pure
        returns (bytes memory)
    {
        uint256 bpp = isIndexed ? 1 : 4;
        uint256 rowCount = bandPixels.length / (uint256(width) * bpp);
        uint256 scaledLength = (rowCount * scaleFactor) * (1 + uint256(width) * scaleFactor * bpp);
        return isIndexed
            ? scaleIndexed(bandPixels, width, scaledLength, scaleFactor)
            : scale(bandPixels, scaledLength, 4 * uint256(width), scaleFactor);
    }

    // =============================================================
    // Chunk patchers: APNG playback control on a finished buffer
    // =============================================================

    /// @notice Thrown when a chunk patcher cannot find its target chunk (the
    ///         buffer is not an APNG, or the frame index is out of range).
    error ChunkNotFound();

    /// @notice Sets an APNG's play count: rewrites the acTL chunk's `num_plays`
    ///         (0 = loop forever, the encoder's default) and its CRC in the
    ///         given buffer, and returns it. Every other byte is untouched, so
    ///         the goldens' pins survive `withLoopCount(png, 0)`.
    /// @param  png   A finished APNG from this encoder (patched in place).
    /// @param  loops How many times to play the animation; 0 plays forever.
    function withLoopCount(bytes memory png, uint32 loops) public pure returns (bytes memory) {
        uint256 off = _findChunk(png, 0x6163544C, 0); // "acTL"
        writeUInt32BE(png, off + 8 + 4, loops); // data: num_frames(4) | num_plays(4)
        _rewriteChunkCrc(png, off);
        return png;
    }

    /// @notice Sets one frame's dispose and blend ops: rewrites that frame's
    ///         fcTL chunk and its CRC in the given buffer, and returns it. The
    ///         encoder emits DISPOSE_OP_NONE / BLEND_OP_OVER; this unlocks the
    ///         rest of the APNG semantic space (e.g. BLEND_OP_SOURCE so a
    ///         frame's alpha *replaces* the canvas instead of compositing).
    /// @param  png        A finished APNG from this encoder (patched in place).
    /// @param  frameIndex Which frame's fcTL to patch, counting from 0.
    /// @param  disposeOp  0 = none, 1 = background, 2 = previous.
    /// @param  blendOp    0 = source, 1 = over.
    function withFrameControl(bytes memory png, uint256 frameIndex, uint8 disposeOp, uint8 blendOp)
        public
        pure
        returns (bytes memory)
    {
        if (disposeOp > 2 || blendOp > 1) revert InvalidFrame();
        uint256 off = _findChunk(png, 0x6663544C, frameIndex); // "fcTL"
        // data: seq(4) w(4) h(4) x(4) y(4) delayNum(2) delayDen(2) dispose(1) blend(1)
        png[off + 8 + 24] = bytes1(disposeOp);
        png[off + 8 + 25] = bytes1(blendOp);
        _rewriteChunkCrc(png, off);
        return png;
    }

    /// @dev Walks the chunk chain for the `skip`-th chunk tagged `tag`;
    ///      returns the offset of its length field.
    function _findChunk(bytes memory png, uint32 tag, uint256 skip) private pure returns (uint256 off) {
        uint256 n = png.length;
        off = PNG_HEADER_LENGTH;
        while (off + 8 <= n) {
            uint256 len;
            uint256 t;
            assembly {
                let w := mload(add(add(png, 0x20), off))
                len := shr(224, w)
                t := and(shr(192, w), 0xffffffff)
            }
            if (t == tag) {
                if (skip == 0) return off;
                skip--;
            }
            off += CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + len + CRC32_LENGTH;
        }
        revert ChunkNotFound();
    }

    /// @dev Recomputes the CRC of the chunk at `off` (over its tag + data).
    function _rewriteChunkCrc(bytes memory png, uint256 off) private pure {
        uint256 len;
        uint256 ptr;
        assembly {
            len := shr(224, mload(add(add(png, 0x20), off)))
            ptr := add(add(png, 0x20), add(off, 4))
        }
        uint32 crc = _crc32Ptr(0xFFFFFFFF, ptr, CHUNK_HEADER_LENGTH + len, _crcTable()) ^ 0xFFFFFFFF;
        writeUInt32BE(png, off + CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + len, crc);
    }

    /// @notice Closes the stream: a final empty DEFLATE block and the adler-32
    ///         in one last IDAT, then IEND. Append after the last band.
    /// @param  adlerState The adler state returned by the last band.
    function pngStreamTrailer(uint32 adlerState) external pure returns (bytes memory) {
        bytes memory tail = Buffer.allocate(DEFLATE_BLOCK_LENGTH + ADLER_CHECKSUM_LENGTH);
        appendDeflateBlockHeader(tail, 0, true); // empty final block (BFINAL = 1)
        tail.appendUint32(adlerState);

        bytes memory iend = Buffer.allocate(CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + CRC32_LENGTH);
        iend.appendUint32(0);
        iend.append(IEND_HEADER);
        iend.appendUint32(IEND_CRC32);

        return bytes.concat(_dataIdat(tail), iend);
    }

    /// @dev Stored (uncompressed), non-final DEFLATE blocks for `scanlines`.
    function _storedBlocks(bytes memory scanlines) private pure returns (bytes memory out) {
        uint256 total = scanlines.length;
        uint256 numBlocks = (total + DEFLATE_MAX_BLOCK_SIZE - 1) / DEFLATE_MAX_BLOCK_SIZE;
        if (numBlocks == 0) numBlocks = 1;
        out = Buffer.allocate(DEFLATE_BLOCK_LENGTH * numBlocks + total);
        if (total == 0) {
            appendDeflateBlockHeader(out, 0, false);
            return out;
        }
        uint256 offset;
        while (offset < total) {
            uint256 remaining = total - offset;
            uint256 blockLength = remaining > DEFLATE_MAX_BLOCK_SIZE ? DEFLATE_MAX_BLOCK_SIZE : remaining;
            appendDeflateBlockHeader(out, blockLength, false); // non-final; the trailer ends the stream
            out.appendSlice(scanlines, offset, blockLength);
            offset += blockLength;
        }
    }

    /// @dev Wraps arbitrary bytes as an IDAT chunk: length · "IDAT" · data · CRC.
    function _dataIdat(bytes memory data) private pure returns (bytes memory idat) {
        idat = Buffer.allocate(CHUNK_LENGTH_BYTES + CHUNK_HEADER_LENGTH + data.length + CRC32_LENGTH);
        idat.appendUint32(uint32(data.length));
        idat.append(IDAT_HEADER);
        idat.append(data);
        idat.appendUint32(crc32WithStart(IDAT_CRC32, data));
    }

    /// @dev Writes a framed IHDR chunk with the given colour type (6 truecolor,
    ///      3 indexed).
    function _ihdrFramed(bytes memory buffer, uint32 width, uint32 height, uint8 scaleFactor, uint8 colorType)
        private
        pure
    {
        bytes memory ihdr = Buffer.allocate(CHUNK_HEADER_LENGTH + IHDR_CHUNK_LENGTH);
        ihdr.append(IHDR_HEADER);
        ihdr.appendUint32(width * scaleFactor);
        ihdr.appendUint32(height * scaleFactor);
        ihdr.appendUint8(8); // bit depth
        ihdr.appendUint8(colorType);
        ihdr.appendUint8(0); // compression
        ihdr.appendUint8(0); // filter
        ihdr.appendUint8(0); // interlace
        buffer.appendUint32(IHDR_CHUNK_LENGTH);
        buffer.append(ihdr);
        buffer.appendUint32(crc32(ihdr));
    }
}
