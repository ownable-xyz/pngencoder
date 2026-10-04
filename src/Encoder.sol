// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wattsy
//
//   █▀█ █▄░█ █▀▀
//   █▀▀ █░▀█ █░█   a fully on-chain
//   ▀░░ ▀░░▀ ▀▀▀   PNG / APNG encoder
//
//  ── Encoder ── base64 output and the encoder's shared scaffolding

pragma solidity ^0.8.24;

import "./ERC165.sol";

import "./IAnimationEncoder.sol";
import "./Animation.sol";

/// @title  Encoder
/// @author wattsy
/// @notice Base for an {IAnimationEncoder}: ERC-165 support plus a couple of
///         byte-writing helpers shared by concrete encoders.
abstract contract Encoder is ERC165, IAnimationEncoder {
    /// @notice Writes a uint32 as 4 big-endian bytes at `position` in `buffer`.
    /// @param  buffer   The buffer to write into.
    /// @param  position Byte offset to write at.
    /// @param  value    The value to write.
    /// @return The offset just past the written bytes.
    function writeUInt32BE(bytes memory buffer, uint256 position, uint32 value) internal pure returns (uint256) {
        assembly {
            let ptr := add(buffer, add(0x20, position))
            mstore8(ptr, and(shr(24, value), 0xFF))
            mstore8(add(ptr, 1), and(shr(16, value), 0xFF))
            mstore8(add(ptr, 2), and(shr(8, value), 0xFF))
            mstore8(add(ptr, 3), and(value, 0xFF))
        }
        return position + 4;
    }

    /// @notice Number of base64 characters `length` input bytes encode to.
    /// @param  length Input length in bytes.
    /// @return The padded base64 output length.
    function calculateBase64Length(uint256 length) internal pure returns (uint256) {
        uint256 remainder = length % 3;
        if (remainder == 0) {
            return (length / 3) * 4;
        } else if (remainder == 1) {
            return ((length + 2) / 3) * 4;
        } else {
            return ((length + 1) / 3) * 4;
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAnimationEncoder).interfaceId || super.supportsInterface(interfaceId);
    }
}
