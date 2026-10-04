// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wattsy
//
//   █▀█ █▄░█ █▀▀
//   █▀▀ █░▀█ █░█   a fully on-chain
//   ▀░░ ▀░░▀ ▀▀▀   PNG / APNG encoder
//
//  ── Deflate ── the compressor behind the stream: LZ77 plus Huffman, RFC 1951

pragma solidity ^0.8.24;

/// @title  Deflate
/// @author wattsy
/// @notice Compresses a byte buffer into a raw DEFLATE stream (RFC 1951).
/// @dev    One block. First an LZ77 pass turns the input into a stream of tokens:
///         literal bytes and (length, distance) back-references found via a
///         hash chain over the 32 KB window, while counting how often each
///         symbol occurs. Then two code books are considered:
///
///           • fixed:   the RFC's predefined Huffman codes (no header cost)
///           • dynamic: optimal, length-limited Huffman codes built from this
///                       block's own symbol counts, transmitted in the header
///
///         Whichever encodes the token stream in fewer bits wins. Dynamic codes
///         spend header bytes to buy shorter codes for common symbols, so they
///         pay off on larger, skewed data; fixed wins on tiny inputs.
library Deflate {
    uint256 private constant MIN_MATCH = 3;
    uint256 private constant MAX_MATCH = 258;
    uint256 private constant WINDOW = 32768;
    uint256 private constant HASH_SIZE = 8192; // 2^13
    uint256 private constant MAX_CHAIN = 32; // chain-walk bound (ratio vs gas)

    uint256 private constant NLIT = 286; // literal/length alphabet (0..285)
    uint256 private constant NDIST = 30; // distance alphabet (0..29)
    uint256 private constant MAX_BITS = 15; // DEFLATE code-length limit
    uint256 private constant MAX_CL_BITS = 7; // code-length alphabet limit

    /// @dev Bit-writer state (memory struct, mutated by reference). Bits pack
    ///      least-significant-first; Huffman codes are pre-reversed in the code
    ///      tables ({_canonicalCodes}) so they emit MSB-first.
    struct Writer {
        bytes out;
        uint256 len;
        uint256 acc;
        uint256 nbits;
    }

    /// @dev The dynamic code book plus its run-length-encoded transmission.
    struct Plan {
        uint8[] litLen;
        uint8[] distLen;
        uint8[] clLen;
        bytes clSyms;
        uint256 clCount;
        uint256 hlit;
        uint256 hdist;
    }

    /// @dev Hoists {SYM_TABLES} from bytecode into memory once per compression
    ///      call. Indexing a `bytes constant` CODECOPYs the whole array on
    ///      every access; the hot loops read these tables several times per
    ///      token, so they are copied exactly once here and then indexed with
    ///      plain MLOADs (see {_lenSym} / {_distSym} for the offsets).
    function _symTables() private pure returns (bytes memory) {
        return SYM_TABLES;
    }

    /// @notice Compresses `data` into a complete raw DEFLATE stream (one final
    ///         block).
    function compress(bytes memory data) public pure returns (bytes memory) {
        return _run(data, true);
    }

    /// @notice Compresses `data` into a non-final, byte-aligned DEFLATE fragment:
    ///         its block is BFINAL=0 and a sync-flush pads the end to a byte
    ///         boundary, so many fragments concatenate into one stream. The match
    ///         window is local to `data` (no back-reference reaches before it),
    ///         which lets each fragment be produced in isolation (e.g. one band
    ///         per `eth_call`). Close the stream with an empty final block.
    function compressBand(bytes memory data) public pure returns (bytes memory) {
        return _run(data, false);
    }

    function _run(bytes memory data, bool finalBlock) private pure returns (bytes memory) {
        uint256 n = data.length;
        bytes memory tab = _symTables();

        // ---- pass 1: LZ77 -> packed tokens + symbol frequencies ----
        // 1 token per byte at most, + EOB; +28 so full-word entry stores in
        // _lz77 can spill zeros past the last entry without touching the next
        // allocation
        bytes memory tokens = new bytes((n + 1) * 4 + 28);
        uint256[] memory litFreq = new uint256[](NLIT);
        uint256[] memory distFreq = new uint256[](NDIST);
        uint256 count = _lz77(data, tokens, litFreq, distFreq, tab);
        litFreq[256] += 1; // end of block
        return _emit(tokens, count, litFreq, distFreq, n, finalBlock, tab);
    }

    /// @notice Compresses `data` into a complete raw DEFLATE stream using only
    ///         run-length (distance-1) back-references and the RFC's fixed Huffman
    ///         codes: a single O(n) pass with no match search.
    /// @dev    {compress} finds matches at any distance via a hash chain, which is
    ///         powerful but costs a chain walk per byte, and a long run of one
    ///         value is its worst case (every position collides). This path skips
    ///         all of that: it only ever copies from one byte back, so a run of N
    ///         equal bytes becomes one literal + one length-(N-1) match. It is far
    ///         cheaper and nearly as small on run-heavy data (flat fills, indexed
    ///         art), and larger on high-entropy data. Fixed codes mean no header.
    function compressRLE(bytes memory data) public pure returns (bytes memory out) {
        uint256 n = data.length;
        out = new bytes(n + (n >> 2) + 64); // literals cost ~9/8 bytes worst case

        // One assembly region with a fully straight-line token loop: run
        // detection (a distance-1 run is a match against the previous byte,
        // found with 32-byte word compares), fixed-book symbol emission and
        // the bit writer, with no function boundaries at all — even Yul
        // functions cost hundreds of gas per call under legacy codegen once
        // they carry a writer state of args and returns, and content that
        // breaks runs often (edges, gradients) pays per token. The distance-1
        // symbol needs no lookup: its reversed code is five zero bits. The
        // table pointers park in memory to stay under the stack cap; the bit
        // accumulator and write cursor stay on the stack. Byte-identical
        // stream, pinned by the RLE goldens.
        uint256[2] memory ctx;
        {
            bytes memory tab = _symTables();
            bytes memory litBook = FIXED_LIT_BOOK; // precomputed: no build, no reversal
            assembly {
                mstore(ctx, add(tab, 0x20))
                mstore(add(ctx, 0x20), add(litBook, 0x20))
            }
        }

        assembly {
            let d := add(data, 0x20)
            let p := add(out, 0x20)
            let acc := 3 // BFINAL=1, BTYPE=01 (fixed): the 3-bit block header
            let nbits := 3

            let i := 0
            for {} lt(i, n) {} {
                // distance-1 run length at i; long runs split naturally: the
                // next iteration re-matches from where this one stopped, and
                // any 1-2 byte tail falls through to literals
                let len := 0
                if i {
                    let ml := sub(n, i)
                    if gt(ml, 258) { ml := 258 } // MAX_MATCH
                    let pj := add(d, sub(i, 1))
                    let pi := add(d, i)
                    for {} iszero(gt(add(len, 32), ml)) {} {
                        let x := xor(mload(add(pj, len)), mload(add(pi, len)))
                        if x {
                            for {} iszero(byte(0, x)) { x := shl(8, x) } { len := add(len, 1) }
                            ml := len // stop the tail loop
                            break
                        }
                        len := add(len, 32)
                    }
                    for {} lt(len, ml) { len := add(len, 1) } {
                        if iszero(eq(byte(0, mload(add(pj, len))), byte(0, mload(add(pi, len))))) { break }
                    }
                }
                switch lt(len, 3)
                case 1 {
                    // literal: one packed-book read, bits appended in place
                    let e := mload(add(mload(add(ctx, 0x20)), mul(byte(0, mload(add(d, i))), 3)))
                    acc := or(acc, shl(nbits, and(shr(232, e), 0xffff)))
                    nbits := add(nbits, byte(0, e))
                    for {} gt(nbits, 7) {} {
                        mstore8(p, acc)
                        p := add(p, 1)
                        acc := shr(8, acc)
                        nbits := sub(nbits, 8)
                    }
                    i := add(i, 1)
                }
                default {
                    // length symbol + extra bits + the distance-1 symbol
                    // (five zero bits: nothing to OR in)
                    let tabd := mload(ctx)
                    let off := byte(0, mload(add(tabd, sub(len, 3)))) // LEN_CODE
                    let e := mload(add(mload(add(ctx, 0x20)), mul(add(257, off), 3)))
                    acc := or(acc, shl(nbits, and(shr(232, e), 0xffff)))
                    nbits := add(nbits, byte(0, e))
                    let eb := byte(0, mload(add(add(tabd, 256), off))) // LEN_XBITS
                    if eb {
                        // extra value = len - LEN_BASE[off]
                        acc := or(acc, shl(nbits, sub(len, shr(240, mload(add(add(tabd, 285), shl(1, off)))))))
                        nbits := add(nbits, eb)
                    }
                    nbits := add(nbits, 5) // distance symbol 0: reversed code 00000
                    for {} gt(nbits, 7) {} {
                        mstore8(p, acc)
                        p := add(p, 1)
                        acc := shr(8, acc)
                        nbits := sub(nbits, 8)
                    }
                    i := add(i, len)
                }
            }
            // end of block: literal/length symbol 256
            {
                let e := mload(add(mload(add(ctx, 0x20)), 768))
                acc := or(acc, shl(nbits, and(shr(232, e), 0xffff)))
                nbits := add(nbits, byte(0, e))
                for {} gt(nbits, 7) {} {
                    mstore8(p, acc)
                    p := add(p, 1)
                    acc := shr(8, acc)
                    nbits := sub(nbits, 8)
                }
            }
            if nbits {
                mstore8(p, acc)
                p := add(p, 1)
            }
            mstore(out, sub(p, add(out, 0x20)))
        }
    }

    /// @dev Chooses fixed vs dynamic codes by encoded size, then writes the block.
    ///      `finalBlock` sets BFINAL; when false the block is followed by a
    ///      sync-flush so the fragment ends on a byte boundary.
    function _emit(
        bytes memory tokens,
        uint256 count,
        uint256[] memory litFreq,
        uint256[] memory distFreq,
        uint256 n,
        bool finalBlock,
        bytes memory tab
    ) private pure returns (bytes memory) {
        Plan memory p = _plan(litFreq, distFreq);
        bytes memory fixLitBook = FIXED_LIT_BOOK; // precomputed: no build, no reversal
        bytes memory fixDistBook = FIXED_DIST_BOOK;

        // Pick fixed vs dynamic codes by encoded size (both sized in one pass).
        bool useDyn = _preferDynamic(tokens, count, fixLitBook, fixDistBook, p, tab);

        Writer memory w;
        w.out = new bytes(n + (n >> 1) + 128);
        // 3-bit block header, LSB-first: BFINAL then BTYPE.
        //   dynamic (BTYPE=10) -> +4, fixed (BTYPE=01) -> +2, final -> +1
        _put(w, (useDyn ? 4 : 2) + (finalBlock ? 1 : 0), 3);
        if (useDyn) {
            _writeHeader(w, p);
            _writeData(w, tokens, count, _packBook(p.litLen), _packBook(p.distLen), tab);
        } else {
            _writeData(w, tokens, count, fixLitBook, fixDistBook, tab);
        }
        if (!finalBlock) _syncFlush(w); // byte-align so the next fragment starts clean
        if (w.nbits > 0) w.out[w.len++] = bytes1(uint8(w.acc));

        bytes memory out = w.out;
        uint256 outLen = w.len;
        assembly {
            mstore(out, outLen)
        }
        return out;
    }

    /// @dev DEFLATE sync-flush: an empty stored block. Its 3-bit header is
    ///      followed by padding to the next byte boundary, then LEN=0 / NLEN=~0,
    ///      so the stream resumes byte-aligned and a following fragment (or the
    ///      final block) can be concatenated verbatim.
    ///
    ///        ...bits | 000 | pad→byte | 00 00 | FF FF |
    ///                  ^hdr            ^LEN     ^NLEN
    function _syncFlush(Writer memory w) private pure {
        _put(w, 0, 3); // empty block header: BFINAL=0, BTYPE=00 (stored)
        if (w.nbits > 0) {
            w.out[w.len++] = bytes1(uint8(w.acc));
            w.acc = 0;
            w.nbits = 0;
        }
        _put(w, 0, 16); // LEN  = 0x0000
        _put(w, 0xFFFF, 16); // NLEN = 0xFFFF (~LEN)
    }

    /// @dev Builds the dynamic code book from the block's frequencies.
    function _plan(uint256[] memory litFreq, uint256[] memory distFreq) private pure returns (Plan memory p) {
        p.litLen = _codeLengths(litFreq, NLIT, MAX_BITS);
        p.distLen = _codeLengths(distFreq, NDIST, MAX_BITS);
        _ensureOneDistance(p.distLen); // a valid block needs >= 1 distance code
        (p.clSyms, p.clCount, p.hlit, p.hdist) = _packCodeLengths(p.litLen, p.distLen);
        p.clLen = _codeLengths(_clFrequencies(p.clSyms, p.clCount), 19, MAX_CL_BITS);
    }

    // ---------------------------------------------------------------- LZ77

    /// @dev LZ77 over `data`: writes packed tokens and tallies symbol counts.
    ///      A token is a literal byte (`< 2^24`) or a match
    ///      (`2^24 | length << 15 | distance`). Returns the token count.
    ///
    ///      One assembly region: the hash chain, match search, quick reject,
    ///      word-at-a-time length compare, insertions and frequency tallies all
    ///      run without per-byte function calls or bounds checks. `tokens` and
    ///      `prev` are written strictly left-to-right, so entries store as a
    ///      full word (the 28 bytes of zeros they spill are unwritten space the
    ///      next store or nothing overwrites — both buffers carry 28 bytes of
    ///      slack); `head` is random-access, so its entries read-modify-write.
    function _lz77(
        bytes memory data,
        bytes memory tokens,
        uint256[] memory litFreq,
        uint256[] memory distFreq,
        bytes memory tab
    ) private pure returns (uint256 count) {
        uint256 n = data.length;
        bytes memory head = new bytes(HASH_SIZE * 4);
        bytes memory prev = new bytes(n * 4 + 28); // +28: full-word entry stores

        // The data pointers park in memory so the assembly below only keeps
        // the hot ones on the stack (legacy codegen's depth cap).
        uint256[7] memory ctx;
        assembly {
            mstore(ctx, add(data, 0x20))
            mstore(add(ctx, 0x20), add(head, 0x20))
            mstore(add(ctx, 0x40), add(prev, 0x20))
            mstore(add(ctx, 0x60), add(tokens, 0x20))
            mstore(add(ctx, 0x80), add(litFreq, 0x20))
            mstore(add(ctx, 0xa0), add(distFreq, 0x20))
            mstore(add(ctx, 0xc0), add(tab, 0x20))
        }

        assembly {
            function hash(ptr) -> h {
                let w := mload(ptr)
                h := and(add(add(mul(byte(0, w), 7919), mul(byte(1, w), 271)), byte(2, w)), 8191)
            }

            // chain a position in: prev[i] = head[h], head[h] = i + 1
            function ins(d, i, n2, hp, pp) {
                if iszero(gt(add(i, 3), n2)) {
                    let hpp := add(hp, shl(2, hash(add(d, i))))
                    mstore(add(pp, shl(2, i)), and(mload(hpp), shl(224, 0xffffffff)))
                    mstore(
                        hpp,
                        or(
                            shl(224, add(i, 1)),
                            and(mload(hpp), 0x00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
                        )
                    )
                }
            }

            // walk the hash chain for the longest match at i (own stack frame)
            function bestMatch(d, i, n2, hp, pp) -> length, dist {
                let cand := shr(224, mload(add(hp, shl(2, hash(add(d, i))))))
                let maxLen := sub(n2, i)
                if gt(maxLen, 258) { maxLen := 258 }
                let pi := add(d, i)
                for { let chain := 32 } 1 { chain := sub(chain, 1) } {
                    if iszero(cand) { break }
                    if iszero(chain) { break }
                    let j := sub(cand, 1)
                    if iszero(lt(sub(i, j), 32768)) { break } // window: dist <= 32767 (packed in 15 bits)
                    let pj := add(d, j)
                    // quick reject (zlib): a candidate can only beat the best
                    // so far if it matches at offset `length`
                    if eq(byte(0, mload(add(pj, length))), byte(0, mload(add(pi, length)))) {
                        // match length: compare 32 bytes at a time, then find
                        // the first differing byte of the odd word; `ml` is
                        // this candidate's own cap so `maxLen` stays intact
                        // for later candidates
                        let ml := maxLen
                        let len := 0
                        for {} iszero(gt(add(len, 32), ml)) {} {
                            let x := xor(mload(add(pj, len)), mload(add(pi, len)))
                            if x {
                                for {} iszero(byte(0, x)) { x := shl(8, x) } { len := add(len, 1) }
                                ml := len // stop the tail loop
                                break
                            }
                            len := add(len, 32)
                        }
                        for {} lt(len, ml) { len := add(len, 1) } {
                            if iszero(eq(byte(0, mload(add(pj, len))), byte(0, mload(add(pi, len))))) { break }
                        }
                        if gt(len, length) {
                            length := len
                            dist := sub(i, j)
                            if iszero(lt(len, maxLen)) { break }
                        }
                    }
                    cand := shr(224, mload(add(pp, shl(2, j))))
                }
            }

            let d := mload(ctx)
            let hp := mload(add(ctx, 0x20))
            let pp := mload(add(ctx, 0x40))

            let i := 0
            for {} lt(i, n) {} {
                let length := 0
                let dist := 0
                if iszero(gt(add(i, 3), n)) { length, dist := bestMatch(d, i, n, hp, pp) }

                switch lt(length, 3)
                case 1 {
                    // ---- literal ----
                    let b := byte(0, mload(add(d, i)))
                    mstore(add(mload(add(ctx, 0x60)), shl(2, count)), shl(224, b))
                    count := add(count, 1)
                    let fp := add(mload(add(ctx, 0x80)), shl(5, b))
                    mstore(fp, add(mload(fp), 1))
                    ins(d, i, n, hp, pp)
                    i := add(i, 1)
                }
                default {
                    // ---- match token + symbol tallies ----
                    mstore(
                        add(mload(add(ctx, 0x60)), shl(2, count)),
                        shl(224, or(0x1000000, or(shl(15, length), dist)))
                    )
                    count := add(count, 1)
                    let tabd := mload(add(ctx, 0xc0))
                    let fp := add(mload(add(ctx, 0x80)), shl(5, add(257, byte(0, mload(add(tabd, sub(length, 3)))))))
                    mstore(fp, add(mload(fp), 1))
                    let idx := sub(dist, 1)
                    if gt(dist, 256) { idx := add(256, shr(7, idx)) }
                    fp := add(mload(add(ctx, 0xa0)), shl(5, byte(0, mload(add(add(tabd, 343), idx)))))
                    mstore(fp, add(mload(fp), 1))
                    // insert every position the match covers
                    for { let end := add(i, length) } lt(i, end) { i := add(i, 1) } { ins(d, i, n, hp, pp) }
                }
            }
        }
    }

    function _get(bytes memory table, uint256 idx) private pure returns (uint256 v) {
        assembly {
            v := shr(224, mload(add(add(table, 0x20), mul(idx, 4))))
        }
    }

    function _set(bytes memory table, uint256 idx, uint256 val) private pure {
        assembly {
            // write the 4-byte entry in one masked word store: `val` (< 2^32)
            // occupies the high 4 bytes, the low 28 (the next entries) are
            // read and written back unchanged.
            let p := add(add(table, 0x20), mul(idx, 4))
            mstore(
                p,
                or(shl(224, val), and(mload(p), 0x00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff))
            )
        }
    }

    // ---------------------------------------------------- symbol tables
    //
    // RFC 1951's length/distance codes, precomputed so a token maps to its symbol
    // in O(1) with no per-call allocation. The `*_CODE` tables map a raw value to
    // its symbol; `*_XBITS`/`*_BASE` give that symbol's extra-bit count and base
    // (so extraVal = value - base). Distances use zlib's split index: direct for
    // dist <= 256, else bucketed by (dist-1) >> 7 into the upper half of the 512-
    // entry table. (Generated; see the code comment in the repo tooling.)

    // One packed constant (adjacent hex literals concatenate), hoisted to
    // memory in a single CODECOPY by {_symTables}. Section offsets:
    //     0..256   LEN_CODE    length-3 -> symbol offset
    //   256..285   LEN_XBITS   symbol offset -> extra-bit count
    //   285..343   LEN_BASE    symbol offset -> base length (2 bytes BE)
    //   343..855   DIST_CODE   zlib split index -> distance symbol
    //   855..885   DIST_XBITS  distance symbol -> extra-bit count
    //   885..945   DIST_BASE   distance symbol -> base distance (2 bytes BE)
    bytes constant SYM_TABLES =
    // LEN_CODE (256 bytes)
     hex"0001020304050607080809090a0a0b0b0c0c0c0c0d0d0d0d0e0e0e0e0f0f0f0f101010101010101011111111111111111212121212121212131313131313131314141414141414141414141414141414151515151515151515151515151515151616161616161616161616161616161617171717171717171717171717171717181818181818181818181818181818181818181818181818181818181818181819191919191919191919191919191919191919191919191919191919191919191a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1c"

        // LEN_XBITS (29 bytes)
        hex"0000000000000000010101010202020203030303040404040505050500"
        // LEN_BASE (58 bytes)
        hex"0003000400050006000700080009000a000b000d000f001100130017001b001f0023002b0033003b0043005300630073008300a300c300e30102"

        // DIST_CODE (512 bytes)
        hex"00010203040405050606060607070707080808080808080809090909090909090a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f000010111212131314141414151515151616161616161616171717171717171718181818181818181818181818181818191919191919191919191919191919191a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d"

        // DIST_XBITS (30 bytes)
        hex"000000000101020203030404050506060707080809090a0a0b0b0c0c0d0d"
        // DIST_BASE (60 bytes)
        hex"0001000200030004000500070009000d001100190021003100410061008100c101010181020103010401060108010c01100118012001300140016001";

    // The RFC's fixed Huffman books, precomputed in {_packBook}'s 3-bytes-per-
    // symbol shape ([length | bit-reversed code, 2 bytes BE]) so the fixed path
    // never builds or reverses a table at runtime. 288 literal/length symbols
    // (0..287: lengths 8/9/7/8 per the RFC's four bands) and 30 distance
    // symbols (all 5 bits). Generated by the canonical-code algorithm below and
    // pinned by the byte-exact goldens.
    bytes constant FIXED_LIT_BOOK = hex"08000c08008c08004c0800cc08002c0800ac08006c0800ec08001c08009c08005c0800dc08003c0800bc08007c0800fc0800020800820800420800c20800220800a20800620800e20800120800920800520800d20800320800b20800720800f208000a08008a08004a0800ca08002a0800aa08006a0800ea08001a08009a08005a0800da08003a0800ba08007a0800fa0800060800860800460800c60800260800a60800660800e60800160800960800560800d60800360800b60800760800f608000e08008e08004e0800ce08002e0800ae08006e0800ee08001e08009e08005e0800de08003e0800be08007e0800fe"
        hex"0800010800810800410800c10800210800a10800610800e10800110800910800510800d10800310800b10800710800f10800090800890800490800c90800290800a90800690800e90800190800990800590800d90800390800b90800790800f90800050800850800450800c50800250800a50800650800e50800150800950800550800d50800350800b50800750800f508000d08008d08004d0800cd08002d0800ad08006d0800ed08001d08009d08005d0800dd08003d0800bd08007d0800fd0900130901130900930901930900530901530900d30901d30900330901330900b30901b30900730901730900f30901f3"
        hex"09000b09010b09008b09018b09004b09014b0900cb0901cb09002b09012b0900ab0901ab09006b09016b0900eb0901eb09001b09011b09009b09019b09005b09015b0900db0901db09003b09013b0900bb0901bb09007b09017b0900fb0901fb0900070901070900870901870900470901470900c70901c70900270901270900a70901a70900670901670900e70901e70900170901170900970901970900570901570900d70901d70900370901370900b70901b70900770901770900f70901f709000f09010f09008f09018f09004f09014f0900cf0901cf09002f09012f0900af0901af09006f09016f0900ef0901ef"
        hex"09001f09011f09009f09019f09005f09015f0900df0901df09003f09013f0900bf0901bf09007f09017f0900ff0901ff0700000700400700200700600700100700500700300700700700080700480700280700680700180700580700380700780700040700440700240700640700140700540700340700740800030800830800430800c30800230800a30800630800e3";
    bytes constant FIXED_DIST_BOOK =
        hex"05000005001005000805001805000405001405000c05001c05000205001205000a05001a05000605001605000e05001e05000105001105000905001905000505001505000d05001d05000305001305000b05001b050007050017";

    /// @dev length (3..258) -> (symbol 257..285, extra bit count, extra value).
    ///      Reads the hoisted {SYM_TABLES}: one byte lookup for the symbol
    ///      offset, one for the extra-bit count, one 2-byte big-endian read for
    ///      the base (offsets documented at the constant).
    function _lenSym(bytes memory tab, uint256 length)
        private
        pure
        returns (uint256 sym, uint256 extraBits, uint256 extraVal)
    {
        assembly {
            let d := add(tab, 0x20)
            let off := byte(0, mload(add(d, sub(length, 3))))
            sym := add(257, off)
            extraBits := byte(0, mload(add(add(d, 256), off)))
            extraVal := sub(length, shr(240, mload(add(add(d, 285), shl(1, off)))))
        }
    }

    /// @dev distance (1..32768) -> (symbol 0..29, extra bit count, extra value).
    function _distSym(bytes memory tab, uint256 dist)
        private
        pure
        returns (uint256 sym, uint256 extraBits, uint256 extraVal)
    {
        assembly {
            let d := add(tab, 0x20)
            // zlib's split index: direct for dist <= 256, else bucketed by
            // (dist-1) >> 7 into the upper half of the 512-entry table
            let idx := sub(dist, 1)
            if gt(dist, 256) { idx := add(256, shr(7, idx)) }
            sym := byte(0, mload(add(add(d, 343), idx)))
            extraBits := byte(0, mload(add(add(d, 855), sym)))
            extraVal := sub(dist, shr(240, mload(add(add(d, 885), shl(1, sym)))))
        }
    }

    // ---------------------------------------------------- Huffman codes

    /// @dev Optimal, length-limited Huffman code lengths for `freq[0..num)`.
    ///      Builds a Huffman tree, then redistributes any length above `maxBits`
    ///      and re-assigns lengths to symbols by frequency (RFC 1951 / zlib).
    ///
    ///      The tree is built with the classic two-queue merge — O(1) per merge
    ///      instead of a scan for the two minima. It picks the same nodes: the
    ///      sorted leaves and the creation-ordered internal nodes are each
    ///      non-decreasing in frequency, so the two global minima are always at
    ///      the queue heads; leaf indices precede internal indices, so the
    ///      old scan's lowest-index tie-breaking is reproduced by preferring
    ///      the leaf on equal frequency and consuming each queue in order.
    ///      (Pinned by the byte-exact goldens and a differential fuzz test —
    ///      `internal` rather than `private` so the fuzz can call it; nothing
    ///      outside this library and its tests uses it.)
    function _codeLengths(uint256[] memory freq, uint256 num, uint256 maxBits)
        internal
        pure
        returns (uint8[] memory len)
    {
        len = new uint8[](num);

        // active symbols
        uint256[] memory sym = new uint256[](num);
        uint256 active = 0;
        assembly {
            let fp := add(freq, 0x20)
            let sp := add(sym, 0x20)
            for { let s := 0 } lt(s, num) { s := add(s, 1) } {
                if mload(add(fp, shl(5, s))) {
                    mstore(add(sp, shl(5, active)), s)
                    active := add(active, 1)
                }
            }
        }
        if (active == 0) return len;
        if (active == 1) {
            len[sym[0]] = 1;
            return len;
        }

        // sort active symbols by frequency ascending (insertion sort — stable,
        // which the tie-breaking depends on; num small)
        assembly {
            let fp := add(freq, 0x20)
            let sp := add(sym, 0x20)
            for { let a := 1 } lt(a, active) { a := add(a, 1) } {
                let v := mload(add(sp, shl(5, a)))
                let fv := mload(add(fp, shl(5, v)))
                let b := a
                for {} gt(b, 0) {} {
                    let prev := mload(add(sp, shl(5, sub(b, 1))))
                    if iszero(gt(mload(add(fp, shl(5, prev))), fv)) { break }
                    mstore(add(sp, shl(5, b)), prev)
                    b := sub(b, 1)
                }
                mstore(add(sp, shl(5, b)), v)
            }
        }

        // Huffman tree over up to 2*active nodes; leaves 0..active-1 map to
        // sym[], internal nodes are created at active, active+1, ...
        uint256 maxNodes = 2 * active;
        uint256[] memory nf = new uint256[](maxNodes); // node frequency
        uint256[] memory par = new uint256[](maxNodes); // parent (0 = root/none)
        uint256[] memory blCount = new uint256[]((maxNodes > maxBits ? maxNodes : maxBits) + 1);
        uint256 maxLen = 0;
        assembly {
            let fp := add(freq, 0x20)
            let sp := add(sym, 0x20)
            let nfp := add(nf, 0x20)
            let pp := add(par, 0x20)
            for { let a := 0 } lt(a, active) { a := add(a, 1) } {
                mstore(add(nfp, shl(5, a)), mload(add(fp, shl(5, mload(add(sp, shl(5, a)))))))
            }

            // two-queue merge: li walks the leaves, ii the internal nodes
            let li := 0
            let ii := active
            let next := active
            for { let m := sub(active, 1) } m { m := sub(m, 1) } {
                let m1 := 0
                let m2 := 0
                // take the leaf iff leaves remain and (no internals remain or
                // leaf freq <= internal freq); reading nf[ii] at ii == next is
                // an unwritten (zero) slot masked out by the ii >= next arm
                switch and(
                    lt(li, active),
                    or(iszero(lt(ii, next)), iszero(gt(mload(add(nfp, shl(5, li))), mload(add(nfp, shl(5, ii))))))
                )
                case 1 {
                    m1 := li
                    li := add(li, 1)
                }
                default {
                    m1 := ii
                    ii := add(ii, 1)
                }
                switch and(
                    lt(li, active),
                    or(iszero(lt(ii, next)), iszero(gt(mload(add(nfp, shl(5, li))), mload(add(nfp, shl(5, ii))))))
                )
                case 1 {
                    m2 := li
                    li := add(li, 1)
                }
                default {
                    m2 := ii
                    ii := add(ii, 1)
                }
                mstore(add(nfp, shl(5, next)), add(mload(add(nfp, shl(5, m1))), mload(add(nfp, shl(5, m2)))))
                mstore(add(pp, shl(5, m1)), next)
                mstore(add(pp, shl(5, m2)), next)
                next := add(next, 1)
            }

            // depth of each leaf = code length (may exceed maxBits; folded
            // back into range by _limit below)
            let lp := add(len, 0x20)
            let bcp := add(blCount, 0x20)
            for { let a := 0 } lt(a, active) { a := add(a, 1) } {
                let d := 0
                let node := a
                for {} mload(add(pp, shl(5, node))) {} {
                    node := mload(add(pp, shl(5, node)))
                    d := add(d, 1)
                }
                mstore(add(lp, shl(5, mload(add(sp, shl(5, a))))), d) // temporary
                let bp := add(bcp, shl(5, d))
                mstore(bp, add(mload(bp), 1))
                if gt(d, maxLen) { maxLen := d }
            }
        }

        _limit(blCount, maxLen, maxBits);

        // re-assign: least frequent symbols get the longest codes
        uint256 p = 0;
        for (uint256 bits = maxBits; bits >= 1; bits--) {
            uint256 c = blCount[bits];
            while (c > 0) {
                len[sym[p++]] = uint8(bits);
                c--;
            }
        }
    }

    /// @dev Fold code lengths above `maxBits` back into the allowed range while
    ///      keeping a valid prefix code (zlib's overflow redistribution).
    function _limit(uint256[] memory blCount, uint256 maxLen, uint256 maxBits) private pure {
        if (maxLen <= maxBits) return;
        uint256 overflow = 0;
        for (uint256 bits = maxBits + 1; bits <= maxLen; bits++) {
            blCount[maxBits] += blCount[bits];
            overflow += blCount[bits];
            blCount[bits] = 0;
        }
        while (overflow > 0) {
            uint256 bits = maxBits - 1;
            while (blCount[bits] == 0) bits--;
            blCount[bits]--;
            blCount[bits + 1] += 2;
            blCount[maxBits]--;
            overflow -= 2;
        }
    }

    /// @dev Canonical codes for the given code lengths (RFC 1951 §3.2.2),
    ///      returned **bit-reversed**, ready for the LSB-first bit writer.
    ///      Huffman codes transmit MSB-first, so each code must be reversed
    ///      before {_put}; doing it once per symbol here replaces a per-token
    ///      reversal in the hot path. Fully assembly: the histogram and
    ///      next-code tables live in scratch memory past the free pointer, and
    ///      each code is reversed with constant-time 16-bit bit swaps.
    function _canonicalCodes(uint8[] memory len) private pure returns (uint256[] memory codes) {
        uint256 num = len.length;
        codes = new uint256[](num);
        assembly {
            // scratch (not allocated): blCount[0..15] at m, nextCode[0..15] after
            let m := mload(0x40)
            calldatacopy(m, calldatasize(), 0x200) // zero the 16 blCount words
            let lp := add(len, 0x20)
            for { let i := 0 } lt(i, num) { i := add(i, 1) } {
                let l := mload(add(lp, shl(5, i)))
                if l {
                    let p := add(m, shl(5, l))
                    mstore(p, add(mload(p), 1))
                }
            }
            let nc := add(m, 0x200)
            let code := 0
            for { let bits := 1 } lt(bits, 16) { bits := add(bits, 1) } {
                code := shl(1, add(code, mload(add(m, shl(5, sub(bits, 1))))))
                mstore(add(nc, shl(5, bits)), code)
            }
            let cp := add(codes, 0x20)
            for { let i := 0 } lt(i, num) { i := add(i, 1) } {
                let l := mload(add(lp, shl(5, i)))
                if l {
                    let ncp := add(nc, shl(5, l))
                    let c := mload(ncp)
                    mstore(ncp, add(c, 1))
                    // reverse the low `l` bits: 16-bit swap network, then shift
                    let r := or(shl(1, and(c, 0x5555)), and(shr(1, c), 0x5555))
                    r := or(shl(2, and(r, 0x3333)), and(shr(2, r), 0x3333))
                    r := or(shl(4, and(r, 0x0f0f)), and(shr(4, r), 0x0f0f))
                    r := or(and(shl(8, r), 0xff00), shr(8, r))
                    mstore(add(cp, shl(5, i)), shr(sub(16, l), r))
                }
            }
        }
    }

    /// @dev Packs a code book as 3 bytes per symbol — [length | reversed code
    ///      (2 bytes BE)] — the shape {_putSym} emits from with a single MLOAD.
    function _packBook(uint8[] memory len) private pure returns (bytes memory book) {
        uint256[] memory codes = _canonicalCodes(len);
        uint256 num = len.length;
        book = new bytes(num * 3);
        assembly {
            let lp := add(len, 0x20)
            let cp := add(codes, 0x20)
            let dst := add(book, 0x20)
            for { let i := 0 } lt(i, num) { i := add(i, 1) } {
                let c := mload(add(cp, shl(5, i)))
                mstore8(dst, mload(add(lp, shl(5, i))))
                mstore8(add(dst, 1), shr(8, c))
                mstore8(add(dst, 2), c)
                dst := add(dst, 3)
            }
        }
    }

    /// @dev A block must define at least one distance code even if unused.
    function _ensureOneDistance(uint8[] memory distLen) private pure {
        for (uint256 s = 0; s < distLen.length; s++) {
            if (distLen[s] != 0) return;
        }
        distLen[0] = 1;
    }

    // ---------------------------------------------- dynamic block header

    /// @dev Run-length encodes the concatenated lit/len + dist code lengths into
    ///      code-length symbols (0-15 literal, 16 repeat-prev, 17/18 zero runs).
    ///      Returns the packed symbol stream, its count, HLIT and HDIST.
    ///      Assembly translation of the reference loop, one branch for one
    ///      branch; entries store as full words (writes are strictly
    ///      left-to-right and the buffer is sized with a word of slack).
    function _packCodeLengths(uint8[] memory litLen, uint8[] memory distLen)
        private
        pure
        returns (bytes memory syms, uint256 count, uint256 hlit, uint256 hdist)
    {
        assembly {
            let llp := add(litLen, 0x20)
            let dlp := add(distLen, 0x20)
            hlit := 286 // NLIT
            for {} and(gt(hlit, 257), iszero(mload(add(llp, shl(5, sub(hlit, 1)))))) {} { hlit := sub(hlit, 1) }
            hdist := 30 // NDIST
            for {} and(gt(hdist, 1), iszero(mload(add(dlp, shl(5, sub(hdist, 1)))))) {} { hdist := sub(hdist, 1) }
        }
        uint256 total = hlit + hdist;
        syms = new bytes(total * 4 + 28); // 1 symbol per position at most, +28 word-store slack
        assembly {
            // the concatenated lengths, read in place (no `all` copy)
            function lenAt(k, llp2, dlp2, hl) -> v {
                switch lt(k, hl)
                case 1 { v := mload(add(llp2, shl(5, k))) }
                default { v := mload(add(dlp2, shl(5, sub(k, hl)))) }
            }

            let llp := add(litLen, 0x20)
            let dlp := add(distLen, 0x20)
            let sp := add(syms, 0x20)
            let i := 0
            for {} lt(i, total) {} {
                let v := lenAt(i, llp, dlp, hlit)
                let run := 1
                for {} and(lt(add(i, run), total), eq(lenAt(add(i, run), llp, dlp, hlit), v)) {} {
                    run := add(run, 1)
                }
                switch iszero(v)
                case 1 {
                    // zero runs: symbol 18 (11-138), symbol 17 (3-10), then 0s
                    for {} iszero(lt(run, 11)) {} {
                        let r := run
                        if gt(r, 138) { r := 138 }
                        mstore(add(sp, shl(2, count)), shl(224, or(18, or(shl(8, 7), shl(12, sub(r, 11))))))
                        count := add(count, 1)
                        run := sub(run, r)
                        i := add(i, r)
                    }
                    for {} iszero(lt(run, 3)) {} {
                        let r := run
                        if gt(r, 10) { r := 10 }
                        mstore(add(sp, shl(2, count)), shl(224, or(17, or(shl(8, 3), shl(12, sub(r, 3))))))
                        count := add(count, 1)
                        run := sub(run, r)
                        i := add(i, r)
                    }
                    for {} run {} {
                        mstore(add(sp, shl(2, count)), 0)
                        count := add(count, 1)
                        run := sub(run, 1)
                        i := add(i, 1)
                    }
                }
                default {
                    // the length itself, then symbol-16 repeats (3-6), then singles
                    mstore(add(sp, shl(2, count)), shl(224, v))
                    count := add(count, 1)
                    run := sub(run, 1)
                    i := add(i, 1)
                    for {} iszero(lt(run, 3)) {} {
                        let r := run
                        if gt(r, 6) { r := 6 }
                        mstore(add(sp, shl(2, count)), shl(224, or(16, or(shl(8, 2), shl(12, sub(r, 3))))))
                        count := add(count, 1)
                        run := sub(run, r)
                        i := add(i, r)
                    }
                    for {} run {} {
                        mstore(add(sp, shl(2, count)), shl(224, v))
                        count := add(count, 1)
                        run := sub(run, 1)
                        i := add(i, 1)
                    }
                }
            }
        }
    }

    // order in which code-length code lengths are transmitted (RFC 1951)
    function _clOrder() private pure returns (uint8[19] memory) {
        return [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
    }

    function _clFrequencies(bytes memory syms, uint256 count) private pure returns (uint256[] memory freq) {
        freq = new uint256[](19);
        for (uint256 k = 0; k < count; k++) {
            freq[_get(syms, k) & 0xFF]++;
        }
    }

    function _headerBits(Plan memory p) private pure returns (uint256 bits) {
        uint8[19] memory order = _clOrder();
        uint256 hclen = 19;
        while (hclen > 4 && p.clLen[order[hclen - 1]] == 0) hclen--;
        bits = 5 + 5 + 4 + hclen * 3;
        for (uint256 k = 0; k < p.clCount; k++) {
            uint256 s = _get(p.clSyms, k);
            bits += p.clLen[s & 0xFF] + ((s >> 8) & 0xF);
        }
    }

    function _writeHeader(Writer memory w, Plan memory p) private pure {
        uint8[19] memory order = _clOrder();
        uint256 hclen = 19;
        while (hclen > 4 && p.clLen[order[hclen - 1]] == 0) hclen--;

        _put(w, p.hlit - 257, 5);
        _put(w, p.hdist - 1, 5);
        _put(w, hclen - 4, 4);
        for (uint256 k = 0; k < hclen; k++) {
            _put(w, p.clLen[order[k]], 3);
        }
        uint256[] memory clCode = _canonicalCodes(p.clLen);
        for (uint256 k = 0; k < p.clCount; k++) {
            uint256 s = _get(p.clSyms, k);
            uint256 v = s & 0xFF;
            _put(w, clCode[v], p.clLen[v]);
            uint256 eb = (s >> 8) & 0xF;
            if (eb > 0) _put(w, (s >> 12) & 0x1FF, eb);
        }
    }

    // ---------------------------------------------- token emission / sizing

    /// @dev True when the dynamic code book (including its header) encodes the
    ///      block in fewer bits than the fixed one.
    function _preferDynamic(
        bytes memory tokens,
        uint256 count,
        bytes memory fixLitBook,
        bytes memory fixDistBook,
        Plan memory p,
        bytes memory tab
    ) private pure returns (bool) {
        (uint256 fixedBits, uint256 dynData) =
            _bothBits(tokens, count, fixLitBook, fixDistBook, p.litLen, p.distLen, tab);
        return _headerBits(p) + dynData < fixedBits;
    }

    /// @dev Encoded data-bit count for the fixed and dynamic code books at once,
    ///      in one pass over the tokens (each match symbol is decoded once, not
    ///      once per book). Returns the totals excluding the dynamic header.
    /// @dev Fixed lengths read from the packed book (byte 0 of each 3-byte
    ///      entry); dynamic lengths from the plan's plain arrays.
    function _bothBits(
        bytes memory tokens,
        uint256 count,
        bytes memory fixLitBook,
        bytes memory fixDistBook,
        uint8[] memory dynLit,
        uint8[] memory dynDist,
        bytes memory tab
    ) private pure returns (uint256 fixedBits, uint256 dynBits) {
        for (uint256 k = 0; k < count; k++) {
            uint256 t = _get(tokens, k);
            if (t < (1 << 24)) {
                fixedBits += _bookBits(fixLitBook, t);
                dynBits += dynLit[t];
            } else {
                // scoped so the length symbol's stack slots free before the
                // distance symbol's (keeps legacy codegen under its depth cap)
                uint256 extra;
                {
                    (uint256 ls, uint256 leb,) = _lenSym(tab, (t >> 15) & 0x1FF);
                    fixedBits += _bookBits(fixLitBook, ls);
                    dynBits += dynLit[ls];
                    extra = leb;
                }
                {
                    (uint256 ds, uint256 deb,) = _distSym(tab, t & 0x7FFF);
                    fixedBits += _bookBits(fixDistBook, ds);
                    dynBits += dynDist[ds];
                    extra += deb;
                }
                fixedBits += extra;
                dynBits += extra;
            }
        }
        fixedBits += _bookBits(fixLitBook, 256); // end of block
        dynBits += dynLit[256];
    }

    /// @dev Code length (in bits) of `sym` in a packed book.
    function _bookBits(bytes memory book, uint256 sym) private pure returns (uint256 nb) {
        assembly {
            nb := byte(0, mload(add(add(book, 0x20), mul(sym, 3))))
        }
    }

    function _writeData(
        Writer memory w,
        bytes memory tokens,
        uint256 count,
        bytes memory litBook,
        bytes memory distBook,
        bytes memory tab
    ) private pure {
        for (uint256 k = 0; k < count; k++) {
            uint256 t = _get(tokens, k);
            if (t < (1 << 24)) {
                _putSym(w, litBook, t);
            } else {
                (uint256 ls, uint256 leb, uint256 lev) = _lenSym(tab, (t >> 15) & 0x1FF);
                _putSym(w, litBook, ls);
                if (leb > 0) _put(w, lev, leb);
                (uint256 ds, uint256 deb, uint256 dev) = _distSym(tab, t & 0x7FFF);
                _putSym(w, distBook, ds);
                if (deb > 0) _put(w, dev, deb);
            }
        }
        _putSym(w, litBook, 256); // end of block
    }

    // ------------------------------------------------------- bit output

    /// @dev Appends the low `nb` bits of `v` to the stream (LSB-first). The
    ///      hottest call in the compressor: full bytes flush straight through
    ///      with raw MSTORE8s — no bounds checks; every caller's `out` is
    ///      pre-sized to the worst case.
    function _put(Writer memory w, uint256 v, uint256 nb) private pure {
        assembly {
            let acc := or(mload(add(w, 0x40)), shl(mload(add(w, 0x60)), v))
            let nbits := add(mload(add(w, 0x60)), nb)
            let len := mload(add(w, 0x20))
            let base := add(mload(w), 0x20)
            for {} gt(nbits, 7) {} {
                mstore8(add(base, len), acc)
                len := add(len, 1)
                acc := shr(8, acc)
                nbits := sub(nbits, 8)
            }
            mstore(add(w, 0x20), len)
            mstore(add(w, 0x40), acc)
            mstore(add(w, 0x60), nbits)
        }
    }

    /// @dev Emits `sym`'s code from a packed book: one MLOAD reads the 3-byte
    ///      entry ([length | reversed code]) and the {_put} body is fused in,
    ///      so a symbol costs a single call.
    function _putSym(Writer memory w, bytes memory book, uint256 sym) private pure {
        assembly {
            let e := mload(add(add(book, 0x20), mul(sym, 3)))
            let acc := or(mload(add(w, 0x40)), shl(mload(add(w, 0x60)), and(shr(232, e), 0xffff)))
            let nbits := add(mload(add(w, 0x60)), byte(0, e))
            let len := mload(add(w, 0x20))
            let base := add(mload(w), 0x20)
            for {} gt(nbits, 7) {} {
                mstore8(add(base, len), acc)
                len := add(len, 1)
                acc := shr(8, acc)
                nbits := sub(nbits, 8)
            }
            mstore(add(w, 0x20), len)
            mstore(add(w, 0x40), acc)
            mstore(add(w, 0x60), nbits)
        }
    }
}
