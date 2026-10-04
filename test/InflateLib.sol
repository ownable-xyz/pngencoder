// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Test-only DEFLATE inflater. It expands a raw DEFLATE stream (stored,
/// fixed-Huffman and dynamic-Huffman blocks). Tests use it to decode the output
/// of this encoder and compare the result with the source.
library InflateLib {
    struct R {
        bytes data;
        uint256 pos;
    }

    /// A canonical Huffman decoder. `count[len]` is the number of codes of each
    /// length. `symbols` is sorted by (length, symbol).
    struct Huff {
        uint256[] count;
        uint256[] symbols;
    }

    uint256 private constant MAX_BITS = 15;

    function _bit(R memory r) internal pure returns (uint256 v) {
        v = (uint256(uint8(r.data[r.pos >> 3])) >> (r.pos & 7)) & 1;
        r.pos++;
    }

    function _bits(R memory r, uint256 nb) internal pure returns (uint256 v) {
        for (uint256 k = 0; k < nb; k++) {
            v |= _bit(r) << k;
        }
    }

    // ---- canonical Huffman ----

    function _buildHuff(uint8[] memory lengths) internal pure returns (Huff memory h) {
        h.count = new uint256[](MAX_BITS + 1);
        for (uint256 s = 0; s < lengths.length; s++) {
            if (lengths[s] != 0) h.count[lengths[s]]++;
        }
        uint256[] memory offset = new uint256[](MAX_BITS + 2);
        for (uint256 len = 1; len <= MAX_BITS; len++) {
            offset[len + 1] = offset[len] + h.count[len];
        }
        h.symbols = new uint256[](offset[MAX_BITS + 1]);
        for (uint256 s = 0; s < lengths.length; s++) {
            if (lengths[s] != 0) {
                h.symbols[offset[lengths[s]]++] = s;
            }
        }
    }

    /// Decodes one symbol. It reads each code from the most significant bit
    /// first.
    function _decode(R memory r, Huff memory h) internal pure returns (uint256) {
        uint256 code = 0;
        uint256 first = 0;
        uint256 index = 0;
        for (uint256 len = 1; len <= MAX_BITS; len++) {
            code |= _bit(r);
            uint256 c = h.count[len];
            if (code - first < c) return h.symbols[index + (code - first)];
            index += c;
            first = (first + c) << 1;
            code <<= 1;
        }
        revert("bad code");
    }

    // ---- length / distance extra bits ----

    function _len(R memory r, uint256 sym) internal pure returns (uint256) {
        uint16[29] memory base = [
            uint16(3),
            4,
            5,
            6,
            7,
            8,
            9,
            10,
            11,
            13,
            15,
            17,
            19,
            23,
            27,
            31,
            35,
            43,
            51,
            59,
            67,
            83,
            99,
            115,
            131,
            163,
            195,
            227,
            258
        ];
        uint8[29] memory extra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
        uint256 i = sym - 257;
        return uint256(base[i]) + _bits(r, extra[i]);
    }

    function _dist(R memory r, uint256 sym) internal pure returns (uint256) {
        uint16[30] memory base = [
            uint16(1),
            2,
            3,
            4,
            5,
            7,
            9,
            13,
            17,
            25,
            33,
            49,
            65,
            97,
            129,
            193,
            257,
            385,
            513,
            769,
            1025,
            1537,
            2049,
            3073,
            4097,
            6145,
            8193,
            12289,
            16385,
            24577
        ];
        uint8[30] memory extra =
            [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
        return uint256(base[sym]) + _bits(r, extra[sym]);
    }

    // ---- fixed code books ----

    function _fixedLitLengths() internal pure returns (uint8[] memory len) {
        len = new uint8[](288);
        for (uint256 s = 0; s < 144; s++) {
            len[s] = 8;
        }
        for (uint256 s = 144; s < 256; s++) {
            len[s] = 9;
        }
        for (uint256 s = 256; s < 280; s++) {
            len[s] = 7;
        }
        for (uint256 s = 280; s < 288; s++) {
            len[s] = 8;
        }
    }

    function _fixedDistLengths() internal pure returns (uint8[] memory len) {
        len = new uint8[](30);
        for (uint256 s = 0; s < 30; s++) {
            len[s] = 5;
        }
    }

    // ---- dynamic header -> two code books ----

    function _dynamicTables(R memory r) internal pure returns (Huff memory litHuff, Huff memory distHuff) {
        uint256 hlit = _bits(r, 5) + 257;
        uint256 hdist = _bits(r, 5) + 1;
        uint256 hclen = _bits(r, 4) + 4;

        uint8[19] memory order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
        uint8[] memory clLen = new uint8[](19);
        for (uint256 k = 0; k < hclen; k++) {
            clLen[order[k]] = uint8(_bits(r, 3));
        }
        Huff memory clHuff = _buildHuff(clLen);

        uint8[] memory lengths = new uint8[](hlit + hdist);
        uint256 idx = 0;
        while (idx < hlit + hdist) {
            uint256 sym = _decode(r, clHuff);
            if (sym < 16) {
                lengths[idx++] = uint8(sym);
            } else if (sym == 16) {
                uint8 prev = lengths[idx - 1];
                for (uint256 rep = _bits(r, 2) + 3; rep > 0; rep--) {
                    lengths[idx++] = prev;
                }
            } else if (sym == 17) {
                for (uint256 rep = _bits(r, 3) + 3; rep > 0; rep--) {
                    lengths[idx++] = 0;
                }
            } else {
                for (uint256 rep = _bits(r, 7) + 11; rep > 0; rep--) {
                    lengths[idx++] = 0;
                }
            }
        }

        uint8[] memory litLen = new uint8[](hlit);
        uint8[] memory distLen = new uint8[](hdist);
        for (uint256 s = 0; s < hlit; s++) {
            litLen[s] = lengths[s];
        }
        for (uint256 s = 0; s < hdist; s++) {
            distLen[s] = lengths[hlit + s];
        }
        litHuff = _buildHuff(litLen);
        distHuff = _buildHuff(distLen);
    }

    // ---- driver ----

    function inflate(bytes memory d) internal pure returns (bytes memory out) {
        R memory r = R(d, 0);
        out = new bytes(0);
        while (true) {
            uint256 bfinal = _bit(r);
            uint256 btype = _bits(r, 2);
            if (btype == 0) {
                r.pos = (r.pos + 7) & ~uint256(7);
                uint256 bi = r.pos >> 3;
                uint256 blen = uint256(uint8(d[bi])) | (uint256(uint8(d[bi + 1])) << 8);
                r.pos += 32;
                for (uint256 k = 0; k < blen; k++) {
                    out = bytes.concat(out, d[r.pos >> 3]);
                    r.pos += 8;
                }
            } else if (btype == 1) {
                out = _decodeBlock(r, _buildHuff(_fixedLitLengths()), _buildHuff(_fixedDistLengths()), out);
            } else if (btype == 2) {
                (Huff memory litHuff, Huff memory distHuff) = _dynamicTables(r);
                out = _decodeBlock(r, litHuff, distHuff, out);
            } else {
                revert("bad btype");
            }
            if (bfinal == 1) break;
        }
    }

    function _decodeBlock(R memory r, Huff memory litHuff, Huff memory distHuff, bytes memory out)
        internal
        pure
        returns (bytes memory)
    {
        while (true) {
            uint256 s = _decode(r, litHuff);
            if (s == 256) break;
            if (s < 256) {
                out = bytes.concat(out, bytes1(uint8(s)));
            } else {
                uint256 length = _len(r, s);
                uint256 distance = _dist(r, _decode(r, distHuff));
                for (uint256 k = 0; k < length; k++) {
                    out = bytes.concat(out, bytes1(out[out.length - distance]));
                }
            }
        }
        return out;
    }

    /// Removes the 2-byte zlib header and the 4-byte Adler trailer, then
    /// inflates.
    function inflateZlib(bytes memory zlib) internal pure returns (bytes memory) {
        bytes memory raw = new bytes(zlib.length - 6);
        for (uint256 i = 0; i < raw.length; i++) {
            raw[i] = zlib[i + 2];
        }
        return inflate(raw);
    }
}
