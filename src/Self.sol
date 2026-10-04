// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wattsy

pragma solidity ^0.8.24;

/// @title  Self
/// @author wattsy
/// @notice Self-describing contracts. A contract reverts with {Describe} when an
///         unknown function is called, handing the caller its own description —
///         so it needs no external documentation to be read. A small idea from
///         wattsyart/self, in answer to "there is no such thing as onchain art."
/// @dev    A fallback can't return state, so the payload rides out on a custom
///         error. The selector is `Describe(bytes)`; the parameter name is
///         cosmetic and doesn't affect it.
library Self {
    error Describe(bytes descriptor);
}
