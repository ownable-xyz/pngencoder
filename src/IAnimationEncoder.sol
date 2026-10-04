// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wattsy
//
//   █▀█ █▄░█ █▀▀
//   █▀▀ █░▀█ █░█   a fully on-chain
//   ▀░░ ▀░░▀ ▀▀▀   PNG / APNG encoder
//
//  ── IAnimationEncoder ── the public encoding interface

pragma solidity ^0.8.24;

import "./Animation.sol";

/// @title  IAnimationEncoder
/// @author wattsy
/// @notice Encodes an {Animation} into an image `data:` URI. The concrete image
///         format (PNG, GIF, …) is chosen by the implementation.
interface IAnimationEncoder {
    /// @notice Encodes `animation` into a `data:image/<format>;base64,…` URI.
    /// @param  animation   The picture to encode.
    /// @param  scaleFactor Integer nearest-neighbour upscale (1 = original size).
    /// @return The image data URI, in the implementation's format.
    function getDataUri(Animation memory animation, uint8 scaleFactor) external view returns (bytes memory);
}
