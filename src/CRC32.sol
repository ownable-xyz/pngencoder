// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wattsy
//
//   █▀█ █▄░█ █▀▀
//   █▀▀ █░▀█ █░█   a fully on-chain
//   ▀░░ ▀░░▀ ▀▀▀   PNG / APNG encoder
//
//  ── CRC32 ── the per-chunk checksum every PNG chunk carries (256-entry table)

pragma solidity ^0.8.24;

/// @title  CRC32
/// @author wattsy
/// @notice The checksum every PNG chunk ends with — the standard CRC-32
///         (ISO-HDLC, poly 0xEDB88320), as specified by the PNG spec
///         (ISO/IEC 15948).
/// @dev    A 256-entry lookup table drives one table read per input byte:
///
///             crc = (crc >> 8) ^ table[(crc ^ byte) & 0xFF]
///
///         The table ships in the bytecode as a packed constant (256 × 4-byte
///         big-endian entries) — no storage reads, ever. Each checksum call
///         CODECOPYs the kilobyte once and unpacks it to 32-byte-spaced words,
///         so the per-byte lookup is a single aligned MLOAD.
///
///         `crc32WithStart` checksums a chunk's type tag and data in one pass,
///         and can continue a running checksum across separate pieces.
contract CRC32 {
    // The standard CRC-32 table for polynomial 0xEDB88320, packed big-endian.
    // Generated from the reference recurrence (c = c&1 ? 0xEDB88320^(c>>1) : c>>1,
    // eight rounds per entry) and cross-checked against the canonical values.
    bytes private constant CRC_TABLE = hex"0000000077073096ee0e612c990951ba076dc419706af48fe963a5359e6495a30edb883279dcb8a4e0d5e91e97d2d98809b64c2b7eb17cbde7b82d0790bf1d911db710646ab020f2f3b9714884be41de1adad47d6ddde4ebf4d4b55183d385c7136c9856646ba8c0fd62f97a8a65c9ec14015c4f63066cd9fa0f3d638d080df53b6e20c84c69105ed56041e4a26771723c03e4d14b04d447d20d85fda50ab56b35b5a8fa42b2986cdbbbc9d6acbcf94032d86ce345df5c75dcd60dcfabd13d5926d930ac51de003ac8d75180bfd0611621b4f4b556b3c423cfba9599b8bda50f2802b89e5f058808c60cd9b2b10be9242f6f7c8758684c11c1611dabb6662d3d"
        hex"76dc419001db710698d220bcefd5102a71b1858906b6b51f9fbfe4a5e8b8d4337807c9a20f00f9349609a88ee10e98187f6a0dbb086d3d2d91646c97e6635c016b6b51f41c6c6162856530d8f262004e6c0695ed1b01a57b8208f4c1f50fc45765b0d9c612b7e9508bbeb8eafcb9887c62dd1ddf15da2d498cd37cf3fbd44c654db261583ab551cea3bc0074d4bb30e24adfa5413dd895d7a4d1c46dd3d6f4fb4369e96a346ed9fcad678846da60b8d044042d7333031de5aa0a4c5fdd0d7cc95005713c270241aabe0b1010c90c20865768b525206f85b3b966d409ce61e49f5edef90e29d9c998b0d09822c7d7a8b459b33d172eb40d81b7bd5c3bc0ba6cad"
        hex"edb883209abfb3b603b6e20c74b1d29aead547399dd277af04db261573dc1683e3630b1294643b840d6d6a3e7a6a5aa8e40ecf0b9309ff9d0a00ae277d079eb1f00f93448708a3d21e01f2686906c2fef762575d806567cb196c36716e6b06e7fed41b7689d32be010da7a5a67dd4accf9b9df6f8ebeeff917b7be4360b08ed5d6d6a3e8a1d1937e38d8c2c44fdff252d1bb67f1a6bc57673fb506dd48b2364bd80d2bdaaf0a1b4c36034af641047a60df60efc3a867df55316e8eef4669be79cb61b38cbc66831a256fd2a05268e236cc0c7795bb0b4703220216b95505262fc5ba3bbeb2bd0b282bb45a925cb36a04c2d7ffa7b5d0cf312cd99e8b5bdeae1d"
        hex"9b64c2b0ec63f226756aa39c026d930a9c0906a9eb0e363f720767850500571395bf4a82e2b87a147bb12bae0cb61b3892d28e9be5d5be0d7cdcefb70bdbdf2186d3d2d4f1d4e24268ddb3f81fda836e81be16cdf6b9265b6fb077e118b7477788085ae6ff0f6a7066063bca11010b5c8f659efff862ae69616bffd3166ccf45a00ae278d70dd2ee4e0483543903b3c2a7672661d06016f74969474d3e6e77dbaed16a4ad9d65adc40df0b6637d83bf0a9bcae53debb9ec547b2cf7f30b5ffe9bdbdf21ccabac28a53b3933024b4a3a6bad03605cdd7069354de572923d967bfb3667a2ec4614ab85d681b022a6f2b94b40bbe37c30c8ea15a05df1b2d02ef8d";

    uint32 private constant MASK = 0xFFFFFFFF;

    /// @notice Computes the CRC-32 of `data`.
    /// @param  data The bytes to checksum.
    /// @return crc  The finalized CRC-32.
    function crc32(bytes memory data) public pure returns (uint32 crc) {
        return crc32WithStart(MASK, data);
    }

    /// @notice Continues a CRC-32 over `data` and finalizes it.
    /// @param  crc  A running CRC to continue (use `0xFFFFFFFF` to start fresh).
    /// @param  data The bytes to fold into the checksum.
    /// @return The finalized CRC-32.
    function crc32WithStart(uint32 crc, bytes memory data) public pure returns (uint32) {
        return crc32WithStart(crc, data, true);
    }

    /// @notice Continues a CRC-32 over `data`, finalizing only if asked.
    /// @dev    Leave `finalize` false to keep folding more pieces into `crc`.
    /// @param  crc      A running CRC to continue.
    /// @param  data     The bytes to fold into the checksum.
    /// @param  finalize Whether to apply the final XOR (0xFFFFFFFF).
    /// @return The CRC-32, finalized when `finalize` is true.
    function crc32WithStart(uint32 crc, bytes memory data, bool finalize) public pure returns (uint32) {
        uint256 ptr;
        assembly {
            ptr := add(data, 0x20)
        }
        crc = _crc32Ptr(crc, ptr, data.length, _crcTable());
        if (finalize) crc = crc ^ MASK;
        return crc;
    }

    /// @dev Unpacks {CRC_TABLE} into memory as 256 words (one aligned MLOAD per
    ///      lookup) and returns the table's memory offset. One CODECOPY plus a
    ///      short unpack loop per call — no storage.
    function _crcTable() internal pure returns (uint256 tablePtr) {
        bytes memory packed = CRC_TABLE;
        assembly {
            tablePtr := mload(0x40)
            mstore(0x40, add(tablePtr, 0x2000))
            let src := add(packed, 0x20)
            for { let j := 0 } lt(j, 256) { j := add(j, 1) } {
                mstore(add(tablePtr, shl(5, j)), shr(224, mload(add(src, shl(2, j)))))
            }
        }
    }

    /// @dev Folds `length` bytes at memory offset `ptr` into `crc` (no final
    ///      XOR), using the unpacked table at `tablePtr`. The primitive behind
    ///      the public functions; encoders use it to checksum a slice of a
    ///      larger buffer without copying it out.
    function _crc32Ptr(uint32 crc, uint256 ptr, uint256 length, uint256 tablePtr) internal pure returns (uint32) {
        assembly {
            function crcByte(c, b, tp) -> nc {
                nc := xor(shr(8, c), mload(add(tp, shl(5, and(xor(c, b), 0xff)))))
            }

            let end := add(ptr, and(length, not(31)))
            for {} lt(ptr, end) { ptr := add(ptr, 0x20) } {
                let w := mload(ptr)
                crc := crcByte(crc, byte(0, w), tablePtr)
                crc := crcByte(crc, byte(1, w), tablePtr)
                crc := crcByte(crc, byte(2, w), tablePtr)
                crc := crcByte(crc, byte(3, w), tablePtr)
                crc := crcByte(crc, byte(4, w), tablePtr)
                crc := crcByte(crc, byte(5, w), tablePtr)
                crc := crcByte(crc, byte(6, w), tablePtr)
                crc := crcByte(crc, byte(7, w), tablePtr)
                crc := crcByte(crc, byte(8, w), tablePtr)
                crc := crcByte(crc, byte(9, w), tablePtr)
                crc := crcByte(crc, byte(10, w), tablePtr)
                crc := crcByte(crc, byte(11, w), tablePtr)
                crc := crcByte(crc, byte(12, w), tablePtr)
                crc := crcByte(crc, byte(13, w), tablePtr)
                crc := crcByte(crc, byte(14, w), tablePtr)
                crc := crcByte(crc, byte(15, w), tablePtr)
                crc := crcByte(crc, byte(16, w), tablePtr)
                crc := crcByte(crc, byte(17, w), tablePtr)
                crc := crcByte(crc, byte(18, w), tablePtr)
                crc := crcByte(crc, byte(19, w), tablePtr)
                crc := crcByte(crc, byte(20, w), tablePtr)
                crc := crcByte(crc, byte(21, w), tablePtr)
                crc := crcByte(crc, byte(22, w), tablePtr)
                crc := crcByte(crc, byte(23, w), tablePtr)
                crc := crcByte(crc, byte(24, w), tablePtr)
                crc := crcByte(crc, byte(25, w), tablePtr)
                crc := crcByte(crc, byte(26, w), tablePtr)
                crc := crcByte(crc, byte(27, w), tablePtr)
                crc := crcByte(crc, byte(28, w), tablePtr)
                crc := crcByte(crc, byte(29, w), tablePtr)
                crc := crcByte(crc, byte(30, w), tablePtr)
                crc := crcByte(crc, byte(31, w), tablePtr)
            }
            let rem := and(length, 31)
            if rem {
                let w := mload(ptr)
                for { let i := 0 } lt(i, rem) { i := add(i, 1) } {
                    crc := crcByte(crc, byte(i, w), tablePtr)
                }
            }
        }
        return crc;
    }
}
