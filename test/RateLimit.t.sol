// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WyecBridge} from "../contracts/WyecBridge.sol";
import {BridgeTestBase} from "./utils/BridgeTestBase.sol";
import {WyecEip712} from "./utils/WyecEip712.sol";

/// The mint rate limit: `mintCap` base units per fixed window `floor(block.timestamp / capWindow)`,
/// shared by both mint paths, set by the guardian threshold (`SetMintLimit`, shared adminNonce).
contract RateLimitTest is BridgeTestBase {
    uint256 constant CAP = 10e8;
    uint256 constant DAY = 1 days;

    function lock(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("rl", i));
    }

    /// Moves to the first second of the next window.
    function nextWindow(uint256 w) internal {
        vm.warp((block.timestamp / w + 1) * w);
    }

    // ------------------------------------------------------------------ the admin act

    function test_SetMintLimit_FlowAndAdminNonce() public {
        assertEq(bridge.adminNonce(), 0);
        vm.expectEmit(false, false, false, true, address(bridge));
        emit MintLimitChanged(CAP, DAY);
        setMintLimit(CAP, DAY);
        assertEq(bridge.mintCap(), CAP);
        assertEq(bridge.capWindow(), DAY);
        assertEq(bridge.mintWindow(), block.timestamp / DAY);
        assertEq(bridge.mintedInWindow(), 0);
        assertEq(bridge.mintAvailable(), CAP);
        assertEq(bridge.adminNonce(), 1);

        // Shared nonce with the other admin acts.
        bridge.setPaused(true, signedSetPaused(true));
        assertEq(bridge.adminNonce(), 2);
        setMintLimit(0, 0);
        assertEq(bridge.adminNonce(), 3);
        assertEq(bridge.mintAvailable(), type(uint256).max);
    }

    function test_SetMintLimit_ReplayRejected() public {
        bytes[] memory sigs = signedSetMintLimit(CAP, DAY);
        bridge.setMintLimit(CAP, DAY, sigs);
        vm.expectRevert(); // adminNonce moved: the old digest recovers to non-guardians
        bridge.setMintLimit(CAP, DAY, sigs);
    }

    function test_SetMintLimit_BelowThresholdOrOutsiderRejected() public {
        bytes32 d = WyecEip712.digest(domainOf(address(bridge)), WyecEip712.setMintLimitStruct(0, 0, 0));
        bytes[] memory one = signSorted(keys(guardianKeys[0]), d);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.Threshold.selector, 1, 2));
        bridge.setMintLimit(0, 0, one);
        bytes[] memory withOutsider = signSorted(keys(guardianKeys[0], outsiderKey), d);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NotGuardian.selector, vm.addr(outsiderKey)));
        bridge.setMintLimit(0, 0, withOutsider);
        // Fields are signed: the pair's signatures over (0, 0) do not authorise (1, 1).
        bytes[] memory pair = signSorted(guardianPair(), d);
        vm.expectRevert();
        bridge.setMintLimit(1, 1, pair);
        assertEq(bridge.adminNonce(), 0);
    }

    function test_SetMintLimit_CapWithoutWindowRejected() public {
        bytes[] memory sigs = signedSetMintLimit(CAP, 0);
        vm.expectRevert(WyecBridge.BadMintLimit.selector);
        bridge.setMintLimit(CAP, 0, sigs);
        assertEq(bridge.adminNonce(), 0); // the whole call reverted, nonce included
    }

    function test_SetMintLimit_WorksWhilePaused() public {
        bridge.setPaused(true, signedSetPaused(true));
        setMintLimit(CAP, DAY);
        assertEq(bridge.mintCap(), CAP);
    }

    // ------------------------------------------------------------------ the limit, threshold path

    function test_ThresholdPath_LimitedAcrossWindows() public {
        setMintLimit(CAP, DAY);
        mintTo(alice, 6e8, lock(1));
        assertEq(bridge.mintAvailable(), 4e8);
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), lock(2), 5e8, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.MintRateLimited.selector, 5e8, 4e8));
        bridge.mint(lock(2), 5e8, alice, sigs);
        assertFalse(bridge.consumed(lock(2)));
        mintTo(alice, 4e8, lock(3));
        assertEq(bridge.mintAvailable(), 0);

        nextWindow(DAY);
        assertEq(bridge.mintAvailable(), CAP);
        bridge.mint(lock(2), 5e8, alice, sigs); // the same signatures, in the next window
        assertEq(bridge.mintAvailable(), 5e8);
        assertEq(token.balanceOf(alice), 15e8);
    }

    /// Windows are fixed (floor), not sliding: the last second of one window and the first of the
    /// next can each take a full cap (design §4.5: worst case 2 × mintCap within any capWindow).
    function test_FixedWindows_BoundaryBurst() public {
        setMintLimit(CAP, DAY);
        vm.warp((block.timestamp / DAY + 1) * DAY - 1);
        mintTo(alice, CAP, lock(1));
        vm.warp(block.timestamp + 1);
        mintTo(alice, CAP, lock(2));
        assertEq(token.balanceOf(alice), 2 * CAP);
    }

    function test_ZeroAmountThresholdMint_UnaffectedByFullWindow() public {
        setMintLimit(CAP, DAY);
        mintTo(alice, CAP, lock(1));
        mintTo(alice, 0, lock(2)); // the threshold path's zero-amount mint is unchanged behaviour
        assertTrue(bridge.consumed(lock(2)));
    }

    // ------------------------------------------------------------------ the limit, optimistic path

    /// A proposal over the remaining budget stays pending and executes in a later window.
    function test_OptimisticPath_LimitedAcrossWindows() public {
        setMintLimit(CAP, DAY);
        propose(guardianKeys[0], lock(1), 8e8, alice);
        propose(guardianKeys[1], lock(2), 8e8, bob);
        vm.warp(block.timestamp + WINDOW);
        uint256 w = block.timestamp / DAY;
        bridge.executeMint(lock(1));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.MintRateLimited.selector, 8e8, 2e8));
        bridge.executeMint(lock(2));
        assertEq(uint8(bridge.proposalStatus(lock(2))), uint8(WyecBridge.ProposalStatus.Ready));

        vm.warp((w + 1) * DAY);
        bridge.executeMint(lock(2));
        assertEq(token.balanceOf(bob), 8e8);
    }

    /// Both paths draw from one budget.
    function test_BothPathsShareTheBudget() public {
        setMintLimit(CAP, DAY);
        nextWindow(DAY);
        propose(guardianKeys[0], lock(1), 4e8, alice);
        mintTo(alice, 7e8, lock(2));
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.MintRateLimited.selector, 4e8, 3e8));
        bridge.executeMint(lock(1));
        // and the other way round
        nextWindow(DAY);
        bridge.executeMint(lock(1));
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), lock(3), 8e8, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.MintRateLimited.selector, 8e8, 6e8));
        bridge.mint(lock(3), 8e8, alice, sigs);
    }

    // ------------------------------------------------------------------ changing the limit

    function test_SetMintLimit_ResetsRunningTotal() public {
        setMintLimit(CAP, DAY);
        mintTo(alice, CAP, lock(1));
        assertEq(bridge.mintAvailable(), 0);
        setMintLimit(CAP, DAY);
        assertEq(bridge.mintAvailable(), CAP);
        assertEq(bridge.mintedInWindow(), 0);
    }

    function test_SetMintLimit_ZeroDisablesThenReenables() public {
        setMintLimit(CAP, DAY);
        mintTo(alice, CAP, lock(1));
        setMintLimit(0, 0);
        mintTo(alice, 3 * CAP, lock(2)); // no limit
        assertEq(bridge.mintedInWindow(), 0); // not counted while disabled
        setMintLimit(CAP, 1 hours);
        assertEq(bridge.mintAvailable(), CAP);
        mintTo(alice, CAP, lock(3));
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), lock(4), 1, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.MintRateLimited.selector, 1, 0));
        bridge.mint(lock(4), 1, alice, sigs);
    }

    // ------------------------------------------------------------------ fuzz

    /// Two mints in one window succeed iff their sum fits the cap; each alone fits iff <= cap.
    function testFuzz_TwoMintsOneWindow(uint256 cap, uint256 a, uint256 b) public {
        cap = bound(cap, 1, token.CAP());
        a = bound(a, 0, token.CAP());
        b = bound(b, 0, token.CAP() - a);
        setMintLimit(cap, DAY);
        nextWindow(DAY);

        bytes[] memory sa = signSorted(guardianPair(), mintDigest(address(bridge), lock(1), a, alice));
        if (a > cap) {
            vm.expectRevert(abi.encodeWithSelector(WyecBridge.MintRateLimited.selector, a, cap));
            bridge.mint(lock(1), a, alice, sa);
            return;
        }
        bridge.mint(lock(1), a, alice, sa);
        assertEq(bridge.mintAvailable(), cap - a);
        bytes[] memory sb = signSorted(guardianPair(), mintDigest(address(bridge), lock(2), b, alice));
        if (a + b > cap) {
            vm.expectRevert(abi.encodeWithSelector(WyecBridge.MintRateLimited.selector, b, cap - a));
            bridge.mint(lock(2), b, alice, sb);
        } else {
            bridge.mint(lock(2), b, alice, sb);
            assertEq(bridge.mintAvailable(), cap - a - b);
        }
    }

    /// For any window length and elapsed time: the budget is used up in the window of the mint and
    /// is full again exactly when floor(t / capWindow) changes.
    function testFuzz_WindowBoundaries(uint256 w, uint256 offset, uint256 elapsed) public {
        w = bound(w, 1, 365 days);
        offset = bound(offset, 0, w - 1);
        elapsed = bound(elapsed, 0, 3 * w);
        setMintLimit(CAP, w);
        vm.warp((block.timestamp / w + 1) * w + offset);
        mintTo(alice, CAP, lock(1));
        assertEq(bridge.mintAvailable(), 0);
        vm.warp(block.timestamp + elapsed);
        bool sameWindow = offset + elapsed < w;
        assertEq(bridge.mintAvailable(), sameWindow ? 0 : CAP);
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), lock(2), CAP, alice));
        if (sameWindow) {
            vm.expectRevert(abi.encodeWithSelector(WyecBridge.MintRateLimited.selector, CAP, 0));
        }
        bridge.mint(lock(2), CAP, alice, sigs);
    }

    /// The running total never exceeds the cap, whatever sequence of mints is attempted.
    function testFuzz_NeverExceedsCap(uint256[8] memory amounts, uint256[8] memory gaps) public {
        uint256 w = 1 hours;
        setMintLimit(CAP, w);
        for (uint256 i = 0; i < 8; i++) {
            uint256 amt = bound(amounts[i], 1, 2 * CAP);
            vm.warp(block.timestamp + bound(gaps[i], 0, w));
            uint256 avail = bridge.mintAvailable();
            bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), lock(i), amt, alice));
            if (amt > avail) {
                vm.expectRevert(abi.encodeWithSelector(WyecBridge.MintRateLimited.selector, amt, avail));
            }
            bridge.mint(lock(i), amt, alice, sigs);
            assertLe(bridge.mintedInWindow(), CAP);
        }
    }
}
