// SPDX-License-Identifier: MIT
// Copyright (c) 2026 The Ycash developers
pragma solidity ^0.8.24;

import {IWyecBridgeConsumed} from "./WyecBridge.sol";

/// @notice The generation-0 adapter (design §4.6): a bridge deployed before `isConsumed`
///         existed exposes only the `consumed(bytes32)` getter. A successor of such a bridge is
///         constructed with `predecessor = new ConsumedView(oldBridge)`, which forwards to it.
///         Deployed once per such migration; holds no state of its own.
interface IConsumedGetter {
    function consumed(bytes32 lockId) external view returns (bool);
}

contract ConsumedView is IWyecBridgeConsumed {
    /// @notice The generation-0 bridge read.
    IConsumedGetter public immutable bridge;

    constructor(IConsumedGetter bridge_) {
        bridge = bridge_;
    }

    function isConsumed(bytes32 lockId) external view returns (bool) {
        return bridge.consumed(lockId);
    }
}
