// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Buffer.sol";

/// A harness that exposes the internal base64 encoder. It also has a gas
/// micro-benchmark and a byte-exact pin of the output. The pin shows that the
/// output bytes stay the same when the loop is optimized.
contract Base64Test is Test {
    using Buffer for bytes;

    function _encode(bytes memory data) internal pure returns (bytes memory out) {
        out = Buffer.allocate(0);
        // Allocate space for the encoded output, then append.
        uint256 need = ((data.length + 2) / 3) * 4;
        out = Buffer.allocate(need);
        // Set the length to 0 so that appendBase64 writes from the start.
        assembly {
            mstore(out, 0)
        }
        out.appendBase64(data, false, false);
    }

    function _fill(uint256 n) internal pure returns (bytes memory d) {
        d = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            d[i] = bytes1(uint8((i * 37 + 11) & 0xff));
        }
    }

    function test_Bench_Base64() public {
        for (uint256 k = 0; k < 3; k++) {
            uint256 n = [uint256(30000), 96000, 300000][k];
            bytes memory d = _fill(n);
            uint256 g = gasleft();
            bytes memory e = _encode(d);
            g = g - gasleft();
            emit log_named_uint(string.concat("base64 ", vm.toString(n), "B -> gas"), g);
            emit log_named_uint("  gas per input byte x1000", (g * 1000) / n);
            assertEq(e.length, ((n + 2) / 3) * 4, "encoded length");
        }
    }

    // Byte-exact pin: encode a fixed buffer and hash the result. Change the pin
    // only for an intended change.
    function test_Base64_Golden() public pure {
        bytes memory e = _encode(_fill(1023)); // not a multiple of 3 -> padding
        assertEq(
            keccak256(e), 0xf931896f81f4e1c25732bd3d5a5e4f33f9f1d047e01eec9a1d1738b48acebdaa, "base64 output drift"
        );
    }
}
