// SPDX-License-Identifier: MIT
// Copyright (c) 2026 The Ycash developers
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Bridgeable} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Bridgeable.sol";

/**
 * Wrapped Ycash (wYEC): the Ethereum side of the Yellowback upgrade plan's bridge (plan §4.3).
 *
 * Stock OpenZeppelin ERC-20 with the ERC-7802 bridgeable extension. The token carries no bridge
 * policy at all: exactly one address, `bridge`, may mint and burn, through `crosschainMint` and
 * `crosschainBurn`. Everything else (guardian signatures, lock ids, Ycash recipients, pause,
 * rotation) lives in that bridge contract, which the guardian set may replace through `setBridge`.
 *
 * Deliberate deltas from the standard, and nothing else:
 *   - decimals() is 8 (zatoshi; matches the 2021 WRY so amounts cross the bridge unscaled)
 *   - the supply is capped at 21,000,000 wYEC, the YEC supply: a free invariant
 *   - _checkTokenBridge is equality against `bridge`
 *   - setBridge, callable only by the current bridge (which requires a guardian threshold)
 *
 * This contract never reads or verifies anything about Ycash (requirement R2).
 */
contract WrappedYcash is ERC20, ERC20Capped, ERC20Permit, ERC20Bridgeable {
    uint256 public constant CAP = 21_000_000 * 1e8;

    address public bridge;

    event BridgeChanged(address indexed previousBridge, address indexed newBridge);

    error NotBridge(address caller);
    error ZeroBridge();

    constructor(address initialBridge)
        ERC20("Wrapped Ycash", "wYEC")
        ERC20Capped(CAP)
        ERC20Permit("Wrapped Ycash")
    {
        if (initialBridge == address(0)) revert ZeroBridge();
        bridge = initialBridge;
        emit BridgeChanged(address(0), initialBridge);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /// Hands the mint/burn right to a successor bridge. Only the current bridge may call it, and
    /// the bridge only does so under its own guardian threshold. No proxy, no admin key.
    function setBridge(address newBridge) external onlyTokenBridge {
        if (newBridge == address(0)) revert ZeroBridge();
        emit BridgeChanged(bridge, newBridge);
        bridge = newBridge;
    }

    function _checkTokenBridge(address caller) internal view override {
        if (caller != bridge) revert NotBridge(caller);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped) {
        super._update(from, to, value);
    }
}
