// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

// =============================================================================
// These buffer libraries for the benchmark are safe for Shanghai. They do not
// use mcopy.
//  - Ethier   : the static DynamicBuffer of ethier/scripty (allocate + word loop)
//  - Solady   : DynamicBufferLib, trimmed to struct/reserve/p/_deallocate
//  - RopeWL   : a word-loop rope (the design of no_side, safe for Shanghai)
//  - Hoisted  : a candidate. Static allocate + unchecked append that loads
//               the buffer length one time
// =============================================================================

/// The static DynamicBuffer core of ethier/scripty. It allocates a large
/// container one time, then appends 32-byte words (divergencetech/ethier ==
/// intartnft/scripty.sol).
library Ethier {
    function allocate(uint256 capacity_) internal pure returns (bytes memory buffer) {
        assembly {
            let container := mload(0x40)
            let size := add(capacity_, 0x60)
            mstore(0x40, add(container, size))
            mstore(container, add(capacity_, 0x40))
            buffer := add(container, 0x20)
            mstore(buffer, 0)
        }
    }

    function appendUnchecked(bytes memory buffer, bytes memory data) internal pure {
        assembly {
            let length := mload(data)
            for {
                data := add(data, 0x20)
                let dataEnd := add(data, length)
                let copyTo := add(buffer, add(mload(buffer), 0x20))
            } lt(data, dataEnd) {
                data := add(data, 0x20)
                copyTo := add(copyTo, 0x20)
            } {
                mstore(copyTo, mload(data))
            }
            mstore(buffer, add(mload(buffer), length))
        }
    }
}

/// A candidate. The allocate is the same as in Ethier. The append loads the
/// buffer length one time. Ethier loads mload(buffer) two times for each
/// append: one time for the write cursor and one time for the length update.
library Hoisted {
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
            let dst := add(add(buffer, 0x20), blen)
            let src := add(data, 0x20)
            let end := add(src, len)
            for {} lt(src, end) {
                src := add(src, 0x20)
                dst := add(dst, 0x20)
            } {
                mstore(dst, mload(src))
            }
            mstore(buffer, add(blen, len))
        }
    }
}

/// Solady DynamicBufferLib, trimmed to the parts that the benchmark uses. `p`,
/// `reserve` and `_deallocate` are exact copies from
/// github.com/Vectorized/solady/blob/main/src/utils/DynamicBufferLib.sol
library DynamicBufferLib {
    struct DynamicBuffer {
        bytes data;
    }

    function reserve(DynamicBuffer memory buffer, uint256 minimum)
        internal
        pure
        returns (DynamicBuffer memory result)
    {
        _deallocate(result);
        result = buffer;
        uint256 n = buffer.data.length;
        if (minimum > n) {
            uint256 i = 0x40;
            do {} while ((i <<= 1) < minimum);
            bytes memory data;
            assembly {
                data := 0x01
                mstore(data, sub(i, n))
            }
            result = p(result, data);
        }
    }

    function p(DynamicBuffer memory buffer, bytes memory data)
        internal
        pure
        returns (DynamicBuffer memory result)
    {
        _deallocate(result);
        result = buffer;
        if (data.length == uint256(0)) return result;
        assembly {
            let w := not(0x1f)
            let bufData := mload(buffer)
            let bufDataLen := mload(bufData)
            let newBufDataLen := add(mload(data), bufDataLen)
            let prime := 1621250193422201
            let cap := mload(add(bufData, w))
            cap := mul(div(cap, prime), iszero(mod(cap, prime)))

            for {} iszero(lt(newBufDataLen, cap)) {} {
                let newCap := and(add(cap, add(or(cap, newBufDataLen), 0x20)), w)
                if iszero(or(xor(mload(0x40), add(bufData, add(0x40, cap))), iszero(cap))) {
                    mstore(add(bufData, w), mul(prime, newCap))
                    mstore(0x40, add(bufData, add(0x40, newCap)))
                    break
                }
                let newBufData := add(mload(0x40), 0x20)
                mstore(0x40, add(newBufData, add(0x40, newCap)))
                mstore(buffer, newBufData)
                for { let o := and(add(bufDataLen, 0x20), w) } 1 {} {
                    mstore(add(newBufData, o), mload(add(bufData, o)))
                    o := add(o, w)
                    if iszero(o) { break }
                }
                mstore(add(newBufData, w), mul(prime, newCap))
                bufData := newBufData
                break
            }
            if eq(data, 0x01) {
                mstore(data, 0x00)
                newBufDataLen := bufDataLen
            }
            for { let o := and(add(mload(data), 0x20), w) } 1 {} {
                mstore(add(add(bufData, bufDataLen), o), mload(add(data, o)))
                o := add(o, w)
                if iszero(o) { break }
            }
            mstore(add(add(bufData, 0x20), newBufDataLen), 0)
            mstore(bufData, newBufDataLen)
        }
    }

    function _deallocate(DynamicBuffer memory result) private pure {
        assembly {
            mstore(0x40, result)
        }
    }
}

/// A word-loop rope. It uses the linked list of chunks from the design of
/// no_side. The final flatten uses a 32-byte word loop that can copy past the
/// end of a chunk, and does not use the Cancun mcopy. Thus it runs on Shanghai.
/// push() is O(1): it stores a pointer to the chunk. flatten() goes through the
/// list one time and copies each chunk exactly one time.
library RopeWL {
    struct Buf {
        uint256 head;
        uint256 tail;
        uint256 total;
    }

    function push(Buf memory b, bytes memory data) internal pure {
        assembly {
            let node := mload(0x40)
            mstore(node, data) // node.dataPtr
            mstore(add(node, 0x20), 0) // node.next
            mstore(0x40, add(node, 0x40))
            let tail := mload(add(b, 0x20))
            switch tail
            case 0 {
                mstore(b, node) // head
                mstore(add(b, 0x20), node) // tail
            }
            default {
                mstore(add(tail, 0x20), node) // tail.next = node
                mstore(add(b, 0x20), node) // tail = node
            }
            mstore(add(b, 0x40), add(mload(add(b, 0x40)), mload(data))) // total += len
        }
    }

    function flatten(Buf memory b) internal pure returns (bytes memory out) {
        assembly {
            let total := mload(add(b, 0x40))
            out := mload(0x40)
            mstore(out, total)
            let base := add(out, 0x20)
            // Reserve the rounded length and one safety word for the over-copy
            // at the tail.
            mstore(0x40, add(base, add(and(add(total, 0x1f), not(0x1f)), 0x20)))

            let cursor := base
            let node := mload(b) // head
            for {} node {} {
                let data := mload(node)
                let len := mload(data)
                let src := add(data, 0x20)
                let end := add(src, len)
                let dst := cursor
                for {} lt(src, end) {
                    src := add(src, 0x20)
                    dst := add(dst, 0x20)
                } {
                    mstore(dst, mload(src)) // may over-write past len; fixed below
                }
                cursor := add(cursor, len) // exact advance; next chunk overwrites overshoot
                node := mload(add(node, 0x20))
            }
        }
    }
}
