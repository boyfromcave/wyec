// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {WrappedYcash} from "../contracts/WrappedYcash.sol";
import {WyecBridge} from "../contracts/WyecBridge.sol";
import {BridgeTestBase} from "./utils/BridgeTestBase.sol";
import {WyecEip712} from "./utils/WyecEip712.sol";

/// The optimistic mint (design §4.5, Hawkeye plan CR-W1): one guardian proposes, any one guardian
/// challenges within `challengeWindow`, anyone executes after it.
contract OptimisticMintTest is BridgeTestBase {
    bytes32 constant LOCK = keccak256("opt-lock");
    uint256 constant AMOUNT = 7e8;

    function proposal(bytes32 lockId) internal view returns (WyecBridge.Proposal memory) {
        return bridge.getProposal(lockId);
    }

    function status(bytes32 lockId) internal view returns (WyecBridge.ProposalStatus) {
        return bridge.proposalStatus(lockId);
    }

    // ------------------------------------------------------------------ propose → window → execute

    function test_ProposeWindowExecute_HappyPath() public {
        uint64 eta = uint64(block.timestamp) + WINDOW;
        vm.expectEmit(true, true, true, true, address(bridge));
        emit MintProposed(LOCK, 1, guardianAddrs[0], alice, AMOUNT, eta);
        vm.prank(bob); // anyone may carry the one guardian signature
        uint256 id = propose(guardianKeys[0], LOCK, AMOUNT, alice);
        assertEq(id, 1);
        assertEq(bridge.proposalCount(), 1);

        WyecBridge.Proposal memory p = proposal(LOCK);
        assertEq(p.to, alice);
        assertEq(p.eta, eta);
        assertEq(p.proposer, guardianAddrs[0]);
        assertEq(p.id, 1);
        assertEq(p.amount, AMOUNT);
        (address to, uint64 e, address proposer, uint96 pid, uint256 amount) = bridge.proposals(LOCK);
        assertEq(
            abi.encode(to, e, proposer, pid, amount), abi.encode(p.to, p.eta, p.proposer, p.id, p.amount)
        );
        assertEq(uint8(status(LOCK)), uint8(WyecBridge.ProposalStatus.Pending));
        assertFalse(bridge.consumed(LOCK));
        assertEq(token.totalSupply(), 0);

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.ChallengeWindowOpen.selector, eta));
        bridge.executeMint(LOCK);

        vm.warp(eta);
        assertEq(uint8(status(LOCK)), uint8(WyecBridge.ProposalStatus.Ready));
        vm.expectEmit(true, true, false, true, address(bridge));
        emit Minted(LOCK, alice, AMOUNT);
        vm.prank(bob);
        bridge.executeMint(LOCK);

        assertEq(token.balanceOf(alice), AMOUNT);
        assertTrue(bridge.consumed(LOCK));
        assertEq(proposal(LOCK).id, 0);
        assertEq(uint8(status(LOCK)), uint8(WyecBridge.ProposalStatus.None));

        // The lock is spent for both paths.
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.LockConsumed.selector, LOCK));
        propose(guardianKeys[1], LOCK, AMOUNT, alice);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NoProposal.selector, LOCK, 0));
        bridge.executeMint(LOCK);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.LockConsumed.selector, LOCK));
        mintTo(alice, AMOUNT, LOCK);
    }

    /// executeMint emits exactly one bridge event (Minted), as the threshold path does.
    function test_Execute_EmitsOnlyMinted() public {
        propose(guardianKeys[0], LOCK, AMOUNT, alice);
        vm.warp(block.timestamp + WINDOW);
        vm.recordLogs();
        bridge.executeMint(LOCK);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(bridge)) {
                n++;
                assertEq(logs[i].topics[0], Minted.selector);
            }
        }
        assertEq(n, 1);
    }

    /// MintProposed topics: [sig, lockId, proposalId, proposer]; data: abi.encode(to, amount, eta).
    function test_Propose_LogLayout() public {
        vm.recordLogs();
        propose(guardianKeys[2], LOCK, AMOUNT, alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        Vm.Log memory l = logs[0];
        assertEq(l.emitter, address(bridge));
        assertEq(l.topics.length, 4);
        assertEq(l.topics[0], keccak256("MintProposed(bytes32,uint256,address,address,uint256,uint64)"));
        assertEq(l.topics[1], LOCK);
        assertEq(l.topics[2], bytes32(uint256(1)));
        assertEq(l.topics[3], bytes32(uint256(uint160(guardianAddrs[2]))));
        assertEq(l.data, abi.encode(alice, AMOUNT, uint64(block.timestamp) + WINDOW));
    }

    function test_Execute_NoProposalReverts() public {
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NoProposal.selector, LOCK, 0));
        bridge.executeMint(LOCK);
    }

    /// One signed message per lock: the proposer's Mint signature also counts on the threshold path.
    function test_SameMintSignatureServesBothPaths() public {
        bytes32 d = mintDigest(address(bridge), LOCK, AMOUNT, alice);
        bytes memory sig0 = sign(guardianKeys[0], d);
        bridge.proposeMint(LOCK, AMOUNT, alice, sig0);
        bytes memory sig1 = sign(guardianKeys[1], d);
        bytes[] memory sigs = new bytes[](2);
        (sigs[0], sigs[1]) = guardianAddrs[0] < guardianAddrs[1] ? (sig0, sig1) : (sig1, sig0);
        bridge.mint(LOCK, AMOUNT, alice, sigs);
        assertEq(token.balanceOf(alice), AMOUNT);
    }

    // ------------------------------------------------------------------ propose rejections

    function test_Propose_NonGuardianSignatureRejected() public {
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NotGuardian.selector, vm.addr(outsiderKey)));
        propose(outsiderKey, LOCK, AMOUNT, alice);
    }

    /// Amount and recipient are signed: a submitter changing either recovers a different (non-guardian)
    /// address.
    function test_Propose_TamperedFieldsRejected() public {
        bytes memory sig = sign(guardianKeys[0], mintDigest(address(bridge), LOCK, AMOUNT, alice));
        address r1 = ECDSA.recover(mintDigest(address(bridge), LOCK, AMOUNT + 1, alice), sig);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NotGuardian.selector, r1));
        bridge.proposeMint(LOCK, AMOUNT + 1, alice, sig);
        address r2 = ECDSA.recover(mintDigest(address(bridge), LOCK, AMOUNT, bob), sig);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NotGuardian.selector, r2));
        bridge.proposeMint(LOCK, AMOUNT, bob, sig);
    }

    function test_Propose_ConsumedLockRejected() public {
        mintTo(alice, AMOUNT, LOCK);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.LockConsumed.selector, LOCK));
        propose(guardianKeys[0], LOCK, AMOUNT, alice);
    }

    /// One live proposal per lockId, also once its window has passed, whoever signs the second.
    function test_Propose_DuplicateLiveProposalRejected() public {
        propose(guardianKeys[0], LOCK, AMOUNT, alice);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.ProposalPending.selector, LOCK, 1));
        propose(guardianKeys[1], LOCK, AMOUNT, alice);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.ProposalPending.selector, LOCK, 1));
        propose(guardianKeys[0], LOCK, 1, bob);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.ProposalPending.selector, LOCK, 1));
        propose(guardianKeys[2], LOCK, AMOUNT, alice);
    }

    function test_Propose_ZeroRecipientOrAmountRejected() public {
        vm.expectRevert(WyecBridge.ZeroRecipient.selector);
        propose(guardianKeys[0], LOCK, AMOUNT, address(0));
        vm.expectRevert(WyecBridge.ZeroAmount.selector);
        propose(guardianKeys[0], LOCK, 0, alice);
    }

    function test_Propose_OtherDeploymentSignatureRejected() public {
        (, WyecBridge other) = deployPair(guardianAddrs, 2);
        bytes memory sig = sign(guardianKeys[0], mintDigest(address(other), LOCK, AMOUNT, alice));
        vm.expectRevert();
        bridge.proposeMint(LOCK, AMOUNT, alice, sig);
    }

    // ------------------------------------------------------------------ challenge

    /// Every guardian, the proposer included, can challenge; anyone submits; the lock stays
    /// unconsumed and a correct mint can be proposed again.
    function test_Challenge_AnyGuardianDeletes_Reproposable() public {
        for (uint256 i = 0; i < guardianKeys.length; i++) {
            bytes32 lock = keccak256(abi.encode("challenge", i));
            uint256 id = propose(guardianKeys[0], lock, AMOUNT, alice);
            vm.expectEmit(true, true, true, true, address(bridge));
            emit MintChallenged(lock, id, guardianAddrs[i]);
            vm.prank(bob);
            challenge(guardianKeys[i], lock, id);
            assertEq(proposal(lock).id, 0);
            assertEq(uint8(status(lock)), uint8(WyecBridge.ProposalStatus.None));
            assertFalse(bridge.consumed(lock));

            vm.warp(block.timestamp + WINDOW);
            vm.expectRevert(abi.encodeWithSelector(WyecBridge.NoProposal.selector, lock, 0));
            bridge.executeMint(lock);

            uint256 id2 = propose(guardianKeys[1], lock, AMOUNT, alice);
            assertEq(id2, id + 1);
            vm.warp(block.timestamp + WINDOW);
            bridge.executeMint(lock);
        }
        assertEq(token.balanceOf(alice), 3 * AMOUNT);
    }

    /// A challenge can come at the last second of the window, and also after it (until execute).
    function test_Challenge_AtAndAfterEta() public {
        uint256 id = propose(guardianKeys[0], LOCK, AMOUNT, alice);
        vm.warp(block.timestamp + WINDOW - 1);
        challenge(guardianKeys[1], LOCK, id);
        id = propose(guardianKeys[0], LOCK, AMOUNT, alice);
        vm.warp(block.timestamp + 10 * WINDOW);
        challenge(guardianKeys[2], LOCK, id);
        assertEq(proposal(LOCK).id, 0);
    }

    /// The proposalId binding: a challenge signature for proposal 1 cannot delete proposal 2.
    function test_Challenge_OldSignatureCannotBlockReproposal() public {
        uint256 id1 = propose(guardianKeys[0], LOCK, AMOUNT, alice);
        bytes memory oldSig = sign(guardianKeys[2], challengeDigest(address(bridge), LOCK, id1));
        bridge.challengeMint(LOCK, id1, oldSig);

        uint256 id2 = propose(guardianKeys[0], LOCK, AMOUNT, alice);
        assertEq(id2, id1 + 1);
        // Replayed as-is: names a proposal that no longer exists.
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NoProposal.selector, LOCK, id1));
        bridge.challengeMint(LOCK, id1, oldSig);
        // Pointed at the new id: the digest differs, so it recovers to a non-guardian.
        address r = ECDSA.recover(challengeDigest(address(bridge), LOCK, id2), oldSig);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NotGuardian.selector, r));
        bridge.challengeMint(LOCK, id2, oldSig);

        vm.warp(block.timestamp + WINDOW);
        bridge.executeMint(LOCK);
        assertEq(token.balanceOf(alice), AMOUNT);
    }

    function test_Challenge_NonGuardianRejected() public {
        uint256 id = propose(guardianKeys[0], LOCK, AMOUNT, alice);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NotGuardian.selector, vm.addr(outsiderKey)));
        challenge(outsiderKey, LOCK, id);
        // A guardian's challenge of another lock does not transfer.
        bytes memory sig = sign(guardianKeys[1], challengeDigest(address(bridge), keccak256("other"), id));
        address r = ECDSA.recover(challengeDigest(address(bridge), LOCK, id), sig);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NotGuardian.selector, r));
        bridge.challengeMint(LOCK, id, sig);
        assertEq(proposal(LOCK).id, id);
    }

    function test_Challenge_UnknownProposalRejected() public {
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NoProposal.selector, LOCK, 0));
        challenge(guardianKeys[0], LOCK, 0);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NoProposal.selector, LOCK, 1));
        challenge(guardianKeys[0], LOCK, 1);
        uint256 id = propose(guardianKeys[0], LOCK, AMOUNT, alice);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NoProposal.selector, LOCK, id + 1));
        challenge(guardianKeys[1], LOCK, id + 1);
    }

    // ------------------------------------------------------------------ interaction with the threshold path

    function test_ThresholdMint_ClearsPendingProposal() public {
        uint256 id = propose(guardianKeys[0], LOCK, AMOUNT, alice);
        mintTo(alice, AMOUNT, LOCK);
        assertEq(proposal(LOCK).id, 0);
        assertEq(uint8(status(LOCK)), uint8(WyecBridge.ProposalStatus.None));
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NoProposal.selector, LOCK, 0));
        bridge.executeMint(LOCK);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NoProposal.selector, LOCK, id));
        challenge(guardianKeys[1], LOCK, id);
        assertEq(token.balanceOf(alice), AMOUNT);
    }

    /// The threshold path may mint a different (amount, to) than a pending proposal: the guardians'
    /// quorum overrides one guardian's proposal.
    function test_ThresholdMint_OverridesWrongProposal() public {
        propose(guardianKeys[0], LOCK, AMOUNT * 2, bob);
        mintTo(alice, AMOUNT, LOCK);
        assertEq(token.balanceOf(alice), AMOUNT);
        assertEq(token.balanceOf(bob), 0);
        assertEq(proposal(LOCK).id, 0);
    }

    // ------------------------------------------------------------------ rotation

    /// A proposer rotated out of the set voids its proposal: execute reverts, the proposal may be
    /// replaced by a current guardian's (or challenged); re-adding the proposer revives it.
    function test_RotatedOutProposer_VoidsProposal() public {
        uint256 id = propose(guardianKeys[0], LOCK, AMOUNT, alice);
        address[] memory g = new address[](2);
        g[0] = guardianAddrs[1];
        g[1] = guardianAddrs[2];
        setGuardians(g, 2);
        assertEq(uint8(status(LOCK)), uint8(WyecBridge.ProposalStatus.Void));

        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.ProposerNotGuardian.selector, guardianAddrs[0]));
        bridge.executeMint(LOCK);

        // The rotated-out key can no longer propose.
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NotGuardian.selector, guardianAddrs[0]));
        propose(guardianKeys[0], LOCK, AMOUNT, alice);

        // Re-adding the proposer revives it (validity is checked at execute) ...
        setGuardians(guardianAddrs, 2, keys(guardianKeys[1], guardianKeys[2]));
        assertEq(uint8(status(LOCK)), uint8(WyecBridge.ProposalStatus.Ready));
        setGuardians(g, 2);

        // ... and a current guardian replaces the void proposal with a fresh window.
        uint64 eta = uint64(block.timestamp) + WINDOW;
        vm.expectEmit(true, true, true, true, address(bridge));
        emit MintProposed(LOCK, id + 1, guardianAddrs[1], alice, AMOUNT, eta);
        propose(guardianKeys[1], LOCK, AMOUNT, alice);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.ChallengeWindowOpen.selector, eta));
        bridge.executeMint(LOCK);
        vm.warp(eta);
        bridge.executeMint(LOCK);
        assertEq(token.balanceOf(alice), AMOUNT);
    }

    function test_RotatedOutProposer_ChallengeStillWorks() public {
        uint256 id = propose(guardianKeys[0], LOCK, AMOUNT, alice);
        address[] memory g = new address[](2);
        g[0] = guardianAddrs[1];
        g[1] = guardianAddrs[2];
        setGuardians(g, 2);
        challenge(guardianKeys[2], LOCK, id);
        assertEq(uint8(status(LOCK)), uint8(WyecBridge.ProposalStatus.None));
        // A rotated-out guardian can no longer challenge.
        id = propose(guardianKeys[1], LOCK, AMOUNT, alice);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NotGuardian.selector, guardianAddrs[0]));
        challenge(guardianKeys[0], LOCK, id);
    }

    // ------------------------------------------------------------------ pause, hand-off, cap

    function test_Pause_BlocksProposeAndExecuteNotChallenge() public {
        uint256 id = propose(guardianKeys[0], LOCK, AMOUNT, alice);
        bridge.setPaused(true, signedSetPaused(true));
        vm.warp(block.timestamp + WINDOW);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.executeMint(LOCK);
        bytes32 lock2 = keccak256("opt-lock-2");
        vm.expectRevert(Pausable.EnforcedPause.selector);
        propose(guardianKeys[0], lock2, 1, alice);

        challenge(guardianKeys[1], LOCK, id);
        assertEq(proposal(LOCK).id, 0);

        // A proposal that ripens during a pause executes once unpaused.
        bridge.setPaused(false, signedSetPaused(false));
        propose(guardianKeys[0], LOCK, AMOUNT, alice);
        bridge.setPaused(true, signedSetPaused(true));
        vm.warp(block.timestamp + WINDOW);
        bridge.setPaused(false, signedSetPaused(false));
        bridge.executeMint(LOCK);
        assertEq(token.balanceOf(alice), AMOUNT);
    }

    /// After a hand-off the old bridge cannot execute; the revert leaves the proposal in place.
    function test_Handoff_ExecuteReverts() public {
        propose(guardianKeys[0], LOCK, AMOUNT, alice);
        address successor = makeAddr("successor");
        bytes32 d = WyecEip712.digest(
            domainOf(address(bridge)), WyecEip712.setBridgeStruct(successor, bridge.adminNonce())
        );
        bridge.setBridge(successor, signSorted(guardianPair(), d));
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(WrappedYcash.NotBridge.selector, address(bridge)));
        bridge.executeMint(LOCK);
        assertEq(proposal(LOCK).id, 1);
        assertFalse(bridge.consumed(LOCK));
    }

    function test_Execute_TokenCapEnforced() public {
        uint256 cap = token.CAP();
        mintTo(alice, cap, keccak256("big"));
        propose(guardianKeys[0], LOCK, 1, alice);
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(ERC20Capped.ERC20ExceededCap.selector, cap + 1, cap));
        bridge.executeMint(LOCK);
        assertEq(proposal(LOCK).id, 1);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_ProposeExecute_Amount(uint256 amount, bytes32 lockId, address to) public {
        amount = bound(amount, 1, token.CAP());
        vm.assume(to != address(0));
        propose(guardianKeys[1], lockId, amount, to);
        vm.warp(block.timestamp + WINDOW);
        bridge.executeMint(lockId);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.totalSupply(), amount);
        assertTrue(bridge.consumed(lockId));
    }

    /// For any challenge window and delay: execute succeeds iff delay >= window.
    function testFuzz_ChallengeWindow(uint64 window, uint64 delay) public {
        window = uint64(bound(window, 1, 365 days));
        delay = uint64(bound(delay, 0, 2 * 365 days));
        (WrappedYcash t, WyecBridge b) = deployPair(guardianAddrs, 2, window, 0, 0);
        b.proposeMint(LOCK, AMOUNT, alice, sign(guardianKeys[0], mintDigest(address(b), LOCK, AMOUNT, alice)));
        uint64 eta = uint64(block.timestamp) + window;
        assertEq(b.getProposal(LOCK).eta, eta);
        vm.warp(block.timestamp + delay);
        if (delay < window) {
            vm.expectRevert(abi.encodeWithSelector(WyecBridge.ChallengeWindowOpen.selector, eta));
            b.executeMint(LOCK);
            assertEq(uint8(b.proposalStatus(LOCK)), uint8(WyecBridge.ProposalStatus.Pending));
        } else {
            b.executeMint(LOCK);
            assertEq(t.balanceOf(alice), AMOUNT);
        }
    }

    /// Proposal ids are unique and strictly increasing across locks, challenges and executions.
    function testFuzz_ProposalIdsIncrease(uint8 n) public {
        n = uint8(bound(n, 1, 20));
        for (uint256 i = 0; i < n; i++) {
            bytes32 lock = keccak256(abi.encode(i % 3));
            uint256 live = bridge.getProposal(lock).id;
            if (live != 0) challenge(guardianKeys[(i + 2) % 3], lock, live);
            uint256 before = bridge.proposalCount();
            uint256 id = propose(guardianKeys[i % 3], lock, AMOUNT, alice);
            assertEq(id, before + 1);
            if (i % 2 == 0) challenge(guardianKeys[(i + 1) % 3], lock, id);
        }
    }
}
