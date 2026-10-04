// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Libs.sol";
import "../src/LibsMcopy.sol";

/// A benchmark for Cancun only. It uses the same three regimes as Bench.t.sol.
/// It also measures each implementation in its own call frame. It compares the
/// mcopy candidates with the word-loop baselines (ethier + solady). It shows
/// the gas that MCOPY saves.
///
/// impl codes: 0 ethier(wordloop) · 2 solady(nores) · 5 mcopy · 6 ropeMcopy(no_side)
contract BenchMcopy is Test {
    bytes32 internal sink;

    function _chunk(uint256 n, uint256 salt) internal pure returns (bytes memory b) {
        b = new bytes(n);
        assembly {
            let p := add(b, 0x20)
            let e := add(p, n)
            let v := add(salt, 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20)
            for {} lt(p, e) { p := add(p, 0x20) } {
                mstore(p, v)
                v := add(v, 1)
            }
        }
    }

    function _g(string memory label, uint256 used, bytes memory out) internal {
        sink = keccak256(abi.encodePacked(sink, out));
        emit log_named_uint(string.concat(label, " len=", vm.toString(out.length), " gas"), used);
    }

    function _build(uint8 impl, uint256 cap, bytes memory ch, uint256 reps)
        internal
        pure
        returns (bytes memory out)
    {
        if (impl == 0) {
            out = Ethier.allocate(cap);
            for (uint256 i; i < reps; i++) Ethier.appendUnchecked(out, ch);
        } else if (impl == 2) {
            DynamicBufferLib.DynamicBuffer memory b;
            for (uint256 i; i < reps; i++) b = DynamicBufferLib.p(b, ch);
            out = b.data;
        } else if (impl == 5) {
            out = Mcopy.allocate(cap);
            for (uint256 i; i < reps; i++) Mcopy.append(out, ch);
        } else {
            RopeMcopy.Buf memory rb;
            for (uint256 i; i < reps; i++) RopeMcopy.push(rb, ch);
            out = RopeMcopy.flatten(rb);
        }
    }

    function _name(uint8 impl) internal pure returns (string memory) {
        if (impl == 0) return "ethier(wordloop) ";
        if (impl == 2) return "solady(wordloop) ";
        if (impl == 5) return "mcopy(static)";
        return "ropeMcopy(noside)";
    }

    function _run(uint8 impl, uint256 cap, uint256 chunkLen, uint256 salt, uint256 reps) internal {
        bytes memory ch = _chunk(chunkLen, salt);
        uint256 g = gasleft();
        bytes memory out = _build(impl, cap, ch, reps);
        g = g - gasleft();
        _g(_name(impl), g, out);
    }

    // ---- M1: single ~300 KB append, size known ----------------------------
    function test_M1_0_ethier() public { _run(0, 300000, 300000, 1, 1); }
    function test_M1_2_solady() public { _run(2, 300000, 300000, 1, 1); }
    function test_M1_5_mcopy() public { _run(5, 300000, 300000, 1, 1); }
    function test_M1_6_ropeMcopy() public { _run(6, 300000, 300000, 1, 1); }

    // ---- M2: 256 x 1 KB, total known (256 KB) -----------------------------
    function test_M2_0_ethier() public { _run(0, 262144, 1024, 7, 256); }
    function test_M2_2_solady() public { _run(2, 262144, 1024, 7, 256); }
    function test_M2_5_mcopy() public { _run(5, 262144, 1024, 7, 256); }
    function test_M2_6_ropeMcopy() public { _run(6, 262144, 1024, 7, 256); }

    // ---- M3: 2000 x 40 B, size unknown (ethier/hoisted cap = floor*) ----------
    function test_M3_0_ethier() public { _run(0, 80000, 40, 3, 2000); }
    function test_M3_2_solady() public { _run(2, 80000, 40, 3, 2000); }
    function test_M3_5_mcopy() public { _run(5, 80000, 40, 3, 2000); }
    function test_M3_6_ropeMcopy() public { _run(6, 80000, 40, 3, 2000); }

    // ---- correctness ------------------------------------------------------
    function test_correctness() public {
        bytes memory ch = _chunk(40, 3);
        bytes32 want = keccak256(_build(0, 80000, ch, 2000));
        assertEq(keccak256(_build(2, 80000, ch, 2000)), want, "solady");
        assertEq(keccak256(_build(5, 80000, ch, 2000)), want, "mcopy");
        assertEq(keccak256(_build(6, 80000, ch, 2000)), want, "ropeMcopy");
    }
}
