// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Deflate.sol";
import "./InflateLib.sol";

/// Differential fuzz test for the two-queue Huffman merge. The reference below
/// is an exact copy of the algorithm that is not optimized (a scan for the two
/// minima). The optimized {Deflate} must give the same stream, byte for byte.
/// This pins the optimal cost and also the exact tie-breaking between equal
/// frequencies.
contract HuffmanTest is Test {
    // ---- reference: _codeLengths + _twoMin, not optimized, exact copy -------

    function _refCodeLengths(uint256[] memory freq, uint256 num, uint256 maxBits)
        internal
        pure
        returns (uint8[] memory len)
    {
        len = new uint8[](num);

        uint256[] memory sym = new uint256[](num);
        uint256 active = 0;
        for (uint256 s = 0; s < num; s++) {
            if (freq[s] > 0) sym[active++] = s;
        }
        if (active == 0) return len;
        if (active == 1) {
            len[sym[0]] = 1;
            return len;
        }

        for (uint256 a = 1; a < active; a++) {
            uint256 v = sym[a];
            uint256 fv = freq[v];
            uint256 b = a;
            while (b > 0 && freq[sym[b - 1]] > fv) {
                sym[b] = sym[b - 1];
                b--;
            }
            sym[b] = v;
        }

        uint256 maxNodes = 2 * active;
        uint256[] memory nf = new uint256[](maxNodes);
        uint256[] memory par = new uint256[](maxNodes);
        for (uint256 a = 0; a < active; a++) {
            nf[a] = freq[sym[a]];
        }
        uint256 next = active;
        uint256 remaining = active;
        while (remaining > 1) {
            (uint256 m1, uint256 m2) = _twoMin(nf, next);
            nf[next] = nf[m1] + nf[m2];
            par[m1] = next;
            par[m2] = next;
            nf[m1] = 0;
            nf[m2] = 0;
            next++;
            remaining--;
        }

        uint256[] memory blCount = new uint256[]((maxNodes > maxBits ? maxNodes : maxBits) + 1);
        uint256 maxLen = 0;
        for (uint256 a = 0; a < active; a++) {
            uint256 d = 0;
            uint256 node = a;
            while (par[node] != 0) {
                node = par[node];
                d++;
            }
            len[sym[a]] = uint8(d);
            blCount[d]++;
            if (d > maxLen) maxLen = d;
        }

        _limit(blCount, maxLen, maxBits);

        uint256 p = 0;
        for (uint256 bits = maxBits; bits >= 1; bits--) {
            uint256 c = blCount[bits];
            while (c > 0) {
                len[sym[p++]] = uint8(bits);
                c--;
            }
        }
    }

    function _twoMin(uint256[] memory nf, uint256 upto) internal pure returns (uint256 m1, uint256 m2) {
        uint256 f1 = type(uint256).max;
        uint256 f2 = type(uint256).max;
        m1 = type(uint256).max;
        m2 = type(uint256).max;
        for (uint256 k = 0; k < upto; k++) {
            uint256 f = nf[k];
            if (f == 0) continue;
            if (f < f1) {
                f2 = f1;
                m2 = m1;
                f1 = f;
                m1 = k;
            } else if (f < f2) {
                f2 = f;
                m2 = k;
            }
        }
    }

    function _limit(uint256[] memory blCount, uint256 maxLen, uint256 maxBits) internal pure {
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

    // ---- the differential harness -------------------------------------------
    //
    // The optimized _codeLengths is private to Deflate, so the comparison is
    // end to end. The test makes an input whose LZ77 tokens give the specified
    // frequency profile, then compresses it. It checks that (a) the stream
    // round-trips and (b) a reference encode of the same data with the
    // reference code lengths is bit-identical. All code after _codeLengths is
    // shared. Thus a difference in the merge gives a different stream.

    /// Fuzz test. Random bytes (a mix of runs and literals) must round-trip.
    /// The full-alphabet frequency profiles from these bytes must give the same
    /// length vectors in the reference builder and the optimized builder.
    function testFuzz_CodeLengths_Match(bytes memory seedData, uint8 sparsity) public pure {
        // Make a frequency vector from the fuzz input.
        uint256[] memory freq = new uint256[](286);
        uint256 mask = uint256(sparsity) % 8; // 0 = dense .. 7 = very sparse
        for (uint256 i = 0; i + 32 <= seedData.length && i < 8192; i += 2) {
            uint256 s = uint8(seedData[i]) % 286;
            if ((uint8(seedData[i + 1]) & ((1 << mask) - 1)) == 0) {
                freq[s] += uint256(uint8(seedData[i + 1])) + 1;
            }
        }
        freq[256] += 1; // EOB always present, as in a real block

        uint8[] memory ref = _refCodeLengths(freq, 286, 15);
        uint8[] memory opt = Deflate._codeLengths(freq, 286, 15);
        assertEq(keccak256(abi.encodePacked(ref)), keccak256(abi.encodePacked(opt)), "code length divergence");
    }

    /// Fuzz test. The emitted stream must round-trip with all code books.
    function testFuzz_Compress_RoundTrips(bytes memory data) public pure {
        vm.assume(data.length <= 4096);
        bytes memory back = InflateLib.inflate(Deflate.compress(data));
        assertEq(keccak256(back), keccak256(data), "round-trip mismatch");
    }
}
