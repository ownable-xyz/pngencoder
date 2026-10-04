// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// =============================================================================
// These variants are for Cancun only (they use the mcopy opcode). Only the
// Cancun run compiles them.
//  - Mcopy : static allocate + mcopy append (the candidate for a known size)
//  - RopeMcopy : the deployed LibDynamicBuffer of no_side (O(1) push + mcopy flatten)
// =============================================================================

/// The candidate for the regime with a known exact size: one allocate, then
/// mcopy appends.
library Mcopy {
    function allocate(uint256 capacity_) internal pure returns (bytes memory buffer) {
        assembly {
            let container := mload(0x40)
            mstore(0x40, add(container, add(capacity_, 0x60)))
            mstore(container, add(capacity_, 0x40))
            buffer := add(container, 0x20)
            mstore(buffer, 0)
        }
    }

    function append(bytes memory buffer, bytes memory data) internal pure {
        assembly {
            let len := mload(data)
            let blen := mload(buffer)
            mcopy(add(add(buffer, 0x20), blen), add(data, 0x20), len)
            mstore(buffer, add(blen, len))
        }
    }
}

/// An accurate copy of the deployed rope of no_side. The source is verified on
/// Etherscan at 0xE3ccab3bC1A943Edd01d3a4B0F7C2B3D74C2b7B0, in the file
/// src/LibDynamicThing.sol. push() appends a 2-word node that points at the chunk and does
/// not copy. flatten() goes through the list one time and copies each chunk
/// into a new bytes value with mcopy.
library RopeMcopy {
    struct Buf {
        uint256 head;
        uint256 tail;
        uint256 total;
    }

    function push(Buf memory b, bytes memory data) internal pure {
        assembly {
            let node := mload(0x40)
            mstore(node, data)
            mstore(add(node, 0x20), 0)
            mstore(0x40, add(node, 0x40))
            let tail := mload(add(b, 0x20))
            switch tail
            case 0 {
                mstore(b, node)
                mstore(add(b, 0x20), node)
            }
            default {
                mstore(add(tail, 0x20), node)
                mstore(add(b, 0x20), node)
            }
            mstore(add(b, 0x40), add(mload(add(b, 0x40)), mload(data)))
        }
    }

    function flatten(Buf memory b) internal pure returns (bytes memory out) {
        assembly {
            let total := mload(add(b, 0x40))
            out := mload(0x40)
            mstore(out, total)
            let base := add(out, 0x20)
            mstore(0x40, add(base, and(add(add(total, 0x20), 0x1f), not(0x1f))))
            let cursor := base
            let node := mload(b)
            for {} node {} {
                let data := mload(node)
                let len := mload(data)
                mcopy(cursor, add(data, 0x20), len)
                cursor := add(cursor, len)
                node := mload(add(node, 0x20))
            }
        }
    }
}
