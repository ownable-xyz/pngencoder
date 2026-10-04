// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wattsy
//
//   █▀█ █▄░█ █▀▀
//   █▀▀ █░▀█ █░█   a fully on-chain
//   ▀░░ ▀░░▀ ▀▀▀   PNG / APNG encoder
//
//  ── Buffer ── the MCOPY-accelerated byte buffer everything is written into
//
//  Lineage (MIT throughout): the base64 encoder below (`appendBase64`) is
//  adapted from Solady, Solmate, and Brecht Devos' base64.sol.

pragma solidity ^0.8.24;

/// @title  Buffer
/// @author wattsy
/// @notice A pre-sized, append-only byte buffer for assembling binary output.
/// @dev    Size the output once, up front, then stream bytes in. Nothing is
///         ever reallocated or copied twice, and a byte run is a single MCOPY.
///
///         The layout is a plain Solidity `bytes` (a length word followed by
///         the data), so a finished buffer is returned directly, no copy:
///
///             buffer ─► ┌──────────────┬────────────────────────────────┐
///                       │  length (32) │  data …                        │
///                       └──────────────┴────────────────────────────────┘
///                                      └─ appends land here ─► grows right
///
///         Appends are UNCHECKED for gas: the caller guarantees the running
///         total never exceeds the `allocate` capacity. Integer appends write
///         exact big-endian bytes; byte runs and slices use MCOPY. Requires the
///         Cancun EVM (MCOPY, EIP-5656).
library Buffer {
    /// @notice Reserves room for `capacity` bytes and returns an empty buffer.
    /// @param  capacity The maximum number of bytes that will be appended.
    /// @return buffer   An empty buffer (length 0) sized for `capacity` bytes.
    function allocate(uint256 capacity) internal pure returns (bytes memory buffer) {
        assembly {
            buffer := mload(0x40)
            mstore(buffer, 0) // length = 0
            mstore(0x40, add(add(buffer, 0x20), and(add(capacity, 0x1f), not(0x1f))))
        }
    }

    /// @notice Appends every byte of `data` to `buffer`.
    /// @param  buffer The destination buffer.
    /// @param  data   The bytes to append.
    function append(bytes memory buffer, bytes memory data) internal pure {
        assembly {
            let len := mload(data)
            let blen := mload(buffer)
            mcopy(add(add(buffer, 0x20), blen), add(data, 0x20), len)
            mstore(buffer, add(blen, len))
        }
    }

    /// @notice Appends a `length`-byte window of `data` starting at `offset`.
    /// @param  buffer The destination buffer.
    /// @param  data   The source bytes.
    /// @param  offset Start index within `data`.
    /// @param  length Number of bytes to copy.
    function appendSlice(bytes memory buffer, bytes memory data, uint256 offset, uint256 length) internal pure {
        assembly {
            let blen := mload(buffer)
            mcopy(add(add(buffer, 0x20), blen), add(add(data, 0x20), offset), length)
            mstore(buffer, add(blen, length))
        }
    }

    /// @notice Appends one byte.
    /// @param  buffer The destination buffer.
    /// @param  value  The byte to append.
    function appendUint8(bytes memory buffer, uint8 value) internal pure {
        assembly {
            let blen := mload(buffer)
            mstore8(add(add(buffer, 0x20), blen), value)
            mstore(buffer, add(blen, 1))
        }
    }

    /// @notice Appends a uint16 as 2 big-endian bytes.
    /// @param  buffer The destination buffer.
    /// @param  value  The value to append.
    function appendUint16(bytes memory buffer, uint16 value) internal pure {
        assembly {
            let blen := mload(buffer)
            let p := add(add(buffer, 0x20), blen)
            mstore8(p, shr(8, value))
            mstore8(add(p, 1), value)
            mstore(buffer, add(blen, 2))
        }
    }

    /// @notice Appends a uint32 as 4 big-endian bytes.
    /// @param  buffer The destination buffer.
    /// @param  value  The value to append.
    function appendUint32(bytes memory buffer, uint32 value) internal pure {
        assembly {
            let blen := mload(buffer)
            let p := add(add(buffer, 0x20), blen)
            mstore8(p, shr(24, value))
            mstore8(add(p, 1), shr(16, value))
            mstore8(add(p, 2), shr(8, value))
            mstore8(add(p, 3), value)
            mstore(buffer, add(blen, 4))
        }
    }

    /// @notice Appends `data` base64-encoded (RFC 4648 §4) to `buffer`.
    /// @dev    Character emission is a per-6-bit table lookup. A 12-bit two-char
    ///         table was tried and measured *slower*: on the EVM a memory read is
    ///         no cheaper than the arithmetic it replaces, so the extra address
    ///         math outweighs halving the lookups. Adapted from Solady, Solmate,
    ///         and Brecht Devos' base64.sol (all MIT).
    /// @param  buffer    The destination buffer.
    /// @param  data      The bytes to encode.
    /// @param  fileSafe  Replace '+' and '/' with '-' and '_'.
    /// @param  noPadding Omit the trailing '=' padding.
    function appendBase64(bytes memory buffer, bytes memory data, bool fileSafe, bool noPadding) internal pure {
        uint256 dataLength = data.length;
        if (dataLength == 0) return;

        uint256 encodedLength;
        uint256 r;
        assembly {
            encodedLength := shl(2, div(add(dataLength, 2), 3))
            r := mod(dataLength, 3)
            if noPadding { encodedLength := sub(encodedLength, add(iszero(iszero(r)), eq(r, 1))) }
        }

        assembly {
            let nextFree := mload(0x40)
            mstore(0x1f, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef")
            mstore(0x3f, sub("ghijklmnopqrstuvwxyz0123456789-_", mul(iszero(fileSafe), 0x0230)))

            let ptr := add(add(buffer, 0x20), mload(buffer))
            let end := add(data, dataLength)

            for {} 1 {} {
                data := add(data, 3)
                let input := mload(data)
                mstore8(ptr, mload(and(shr(18, input), 0x3F)))
                mstore8(add(ptr, 1), mload(and(shr(12, input), 0x3F)))
                mstore8(add(ptr, 2), mload(and(shr(6, input), 0x3F)))
                mstore8(add(ptr, 3), mload(and(input, 0x3F)))
                ptr := add(ptr, 4)
                if iszero(lt(data, end)) { break }
            }

            if iszero(noPadding) {
                mstore8(sub(ptr, iszero(iszero(r))), 0x3d)
                mstore8(sub(ptr, shl(1, eq(r, 1))), 0x3d)
            }

            mstore(buffer, add(mload(buffer), encodedLength))
            mstore(0x40, nextFree)
        }
    }
}
