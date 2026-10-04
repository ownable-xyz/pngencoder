// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "../src/Libs.sol";

/// A benchmark that is safe for Shanghai (no mcopy). It has three regimes:
///  S1  one large append                 (like PNG IDAT: known size, one large copy)
///  S2  many medium appends, known total (assembly of frames or tiles: K appends)
///  S3  many small appends, unknown size (the SVG-string regime)
///
/// The harness measures each implementation in its own test function. That
/// function is a new message call with a new memory high-water mark. It is
/// incorrect to measure more than one implementation in one call. EVM memory
/// expansion only increases in a call frame. Thus the first implementation pays
/// all the expansion gas, and the others look free. Each dispatcher makes its
/// source chunk in the same way before it starts the gas measurement. Thus each
/// implementation allocates its buffer from the same memory level.
///
/// impl codes: 0 ethier · 1 hoisted · 2 solady(nores) · 3 solady(reserve) · 4 ropeWL
contract BenchShanghai is Test {
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
        sink = keccak256(abi.encodePacked(sink, out)); // defeat DCE
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
        } else if (impl == 1) {
            out = Hoisted.allocate(cap);
            for (uint256 i; i < reps; i++) Hoisted.append(out, ch);
        } else if (impl == 2) {
            DynamicBufferLib.DynamicBuffer memory b;
            for (uint256 i; i < reps; i++) b = DynamicBufferLib.p(b, ch);
            out = b.data;
        } else if (impl == 3) {
            DynamicBufferLib.DynamicBuffer memory b;
            b = DynamicBufferLib.reserve(b, cap);
            for (uint256 i; i < reps; i++) b = DynamicBufferLib.p(b, ch);
            out = b.data;
        } else {
            RopeWL.Buf memory rb;
            for (uint256 i; i < reps; i++) RopeWL.push(rb, ch);
            out = RopeWL.flatten(rb);
        }
    }

    string[5] internal NAMES =
        ["ethier(static) ", "hoisted     ", "solady(nores)  ", "solady(reserve)", "ropeWL         "];

    // Each test calls _run one time. Thus each run has a new frame and pays the
    // same memory expansion.
    function _run(uint8 impl, uint256 cap, uint256 chunkLen, uint256 salt, uint256 reps) internal {
        bytes memory ch = _chunk(chunkLen, salt);
        uint256 g = gasleft();
        bytes memory out = _build(impl, cap, ch, reps);
        g = g - gasleft();
        _g(NAMES[impl], g, out);
    }

    // ---- S1: single ~300 KB append, size known -----------------------------
    function test_S1_0_ethier() public { _run(0, 300000, 300000, 1, 1); }
    function test_S1_1_hoisted() public { _run(1, 300000, 300000, 1, 1); }
    function test_S1_2_solady() public { _run(2, 300000, 300000, 1, 1); }
    function test_S1_3_soladyR() public { _run(3, 300000, 300000, 1, 1); }
    function test_S1_4_rope() public { _run(4, 300000, 300000, 1, 1); }

    // ---- S2: 256 x 1 KB, total known (256 KB) ------------------------------
    function test_S2_0_ethier() public { _run(0, 262144, 1024, 7, 256); }
    function test_S2_1_hoisted() public { _run(1, 262144, 1024, 7, 256); }
    function test_S2_2_solady() public { _run(2, 262144, 1024, 7, 256); }
    function test_S2_3_soladyR() public { _run(3, 262144, 1024, 7, 256); }
    function test_S2_4_rope() public { _run(4, 262144, 1024, 7, 256); }

    // ---- S3: 2000 x 40 B, size unknown (ethier/hoisted cap = floor*) ----------
    function test_S3_0_ethier() public { _run(0, 80000, 40, 3, 2000); }
    function test_S3_1_hoisted() public { _run(1, 80000, 40, 3, 2000); }
    function test_S3_2_solady() public { _run(2, 80000, 40, 3, 2000); }
    function test_S3_4_rope() public { _run(4, 80000, 40, 3, 2000); }

    // ---- correctness: each implementation gives the same bytes ---------------
    function test_correctness() public {
        bytes memory ch = _chunk(40, 3);
        bytes32 want = keccak256(_build(0, 80000, ch, 2000));
        assertEq(keccak256(_build(1, 80000, ch, 2000)), want, "hoisted");
        assertEq(keccak256(_build(2, 80000, ch, 2000)), want, "solady");
        assertEq(keccak256(_build(3, 80000, ch, 2000)), want, "soladyReserve");
        assertEq(keccak256(_build(4, 80000, ch, 2000)), want, "ropeWL");
    }
}
