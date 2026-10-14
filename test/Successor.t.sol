// SPDX-License-Identifier: MIT
// Copyright (c) 2026 The Ycash developers
pragma solidity ^0.8.24;

import {ConsumedView, IConsumedGetter} from "../contracts/ConsumedView.sol";
import {WrappedYcash} from "../contracts/WrappedYcash.sol";
import {IWrappedYcash, IWyecBridgeConsumed, WyecBridge} from "../contracts/WyecBridge.sol";
import {BridgeTestBase} from "./utils/BridgeTestBase.sol";
import {WyecEip712} from "./utils/WyecEip712.sol";

/// Migration to a successor bridge (design §4.6, audit 05/L-3): a lockId consumed on any
/// predecessor never mints again, on either path, across a chain of bridges.
contract SuccessorTest is BridgeTestBase {
    bytes32 constant L = keccak256("successor-lock");
    uint256 constant AMOUNT = 5e8;

    /// A successor of `pred` over the base fixture's token, same guardians, threshold 2.
    function successor(IWyecBridgeConsumed pred) internal returns (WyecBridge) {
        return new WyecBridge(IWrappedYcash(address(token)), guardianAddrs, 2, WINDOW, 0, 0, 0, pred);
    }

    /// `from.setBridge(to)` signed by guardians 0 and 1.
    function handOff(WyecBridge from, address to) internal {
        bytes32 d =
            WyecEip712.digest(domainOf(address(from)), WyecEip712.setBridgeStruct(to, from.adminNonce()));
        from.setBridge(to, signSorted(guardianPair(), d));
        assertEq(token.bridge(), to);
    }

    function mintOn(WyecBridge b, bytes32 lockId, uint256 amount) internal {
        b.mint(
            lockId, amount, alice, signSorted(guardianPair(), mintDigest(address(b), lockId, amount, alice))
        );
    }

    function test_Successor_PredecessorConsumedBlocksMint() public {
        mintOn(bridge, L, AMOUNT);
        WyecBridge b = successor(IWyecBridgeConsumed(address(bridge)));
        assertEq(address(b.predecessor()), address(bridge));
        handOff(bridge, address(b));
        assertFalse(b.consumed(L));
        assertTrue(b.isConsumed(L));
        // both mint paths refuse it, with fresh signatures over the successor's domain
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(b), L, AMOUNT, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.LockConsumed.selector, L));
        b.mint(L, AMOUNT, alice, sigs);
        bytes memory one = sign(guardianKeys[0], mintDigest(address(b), L, AMOUNT, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.LockConsumed.selector, L));
        b.proposeMint(L, AMOUNT, alice, one);
        // a fresh lock mints on the successor
        bytes32 l2 = keccak256("fresh");
        mintOn(b, l2, 1e8);
        assertEq(token.balanceOf(alice), AMOUNT + 1e8);
        // a chain of three: C succeeds B, which succeeded A; both old locks stay consumed
        WyecBridge c = successor(IWyecBridgeConsumed(address(b)));
        handOff(b, address(c));
        assertTrue(c.isConsumed(L));
        assertTrue(c.isConsumed(l2));
        sigs = signSorted(guardianPair(), mintDigest(address(c), L, AMOUNT, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.LockConsumed.selector, L));
        c.mint(L, AMOUNT, alice, sigs);
        sigs = signSorted(guardianPair(), mintDigest(address(c), l2, 1e8, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.LockConsumed.selector, l2));
        c.mint(l2, 1e8, alice, sigs);
        assertFalse(c.isConsumed(keccak256("never")));
    }

    function test_Successor_OldBridgeCannotMintAfterHandoff() public {
        WyecBridge b = successor(IWyecBridgeConsumed(address(bridge)));
        handOff(bridge, address(b));
        bytes32 l3 = keccak256("l3");
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), l3, AMOUNT, alice));
        vm.expectRevert(abi.encodeWithSelector(WrappedYcash.NotBridge.selector, address(bridge)));
        bridge.mint(l3, AMOUNT, alice, sigs);
    }

    /// A proposal opened on the successor while its predecessor was still the token's bridge, for
    /// a lock the predecessor then minted: executing it after the hand-off is refused
    /// (`_mint` re-checks `isConsumed`).
    function test_Successor_ProposalBeforePredecessorMintedNeverExecutes() public {
        WyecBridge b = successor(IWyecBridgeConsumed(address(bridge)));
        b.proposeMint(L, AMOUNT, alice, sign(guardianKeys[0], mintDigest(address(b), L, AMOUNT, alice)));
        mintOn(bridge, L, AMOUNT);
        handOff(bridge, address(b));
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.LockConsumed.selector, L));
        b.executeMint(L);
        assertEq(token.totalSupply(), AMOUNT);
    }

    /// A generation-0 bridge (only the `consumed` getter) is read through `ConsumedView`.
    function test_Successor_ConsumedViewForwardsTheGetter() public {
        mintOn(bridge, L, AMOUNT);
        ConsumedView v = new ConsumedView(IConsumedGetter(address(bridge)));
        assertTrue(v.isConsumed(L));
        assertFalse(v.isConsumed(keccak256("other")));
        WyecBridge b = successor(v);
        handOff(bridge, address(b));
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(b), L, AMOUNT, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.LockConsumed.selector, L));
        b.mint(L, AMOUNT, alice, sigs);
    }

    /// The cost of the predecessor check: one extra STATICCALL per mint, only with a predecessor.
    function test_Successor_MintGas() public {
        WyecBridge b = successor(IWyecBridgeConsumed(address(bridge)));
        mintOn(bridge, keccak256("warm-a"), 1); // first mints pay the cold slots; compare later ones
        uint256 g0 = gasleft();
        mintOn(bridge, keccak256("g0"), 1);
        uint256 plain = g0 - gasleft();
        handOff(bridge, address(b));
        mintOn(b, keccak256("warm-b"), 1);
        g0 = gasleft();
        mintOn(b, keccak256("g1"), 1);
        uint256 succ = g0 - gasleft();
        emit log_named_uint("mint gas, no predecessor", plain);
        emit log_named_uint("mint gas, one predecessor", succ);
        assertGt(succ, plain, "the predecessor read costs something");
        assertLt(succ, plain + 10_000, "one STATICCALL and a cold SLOAD there");
    }
}
