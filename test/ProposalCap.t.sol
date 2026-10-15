// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IWrappedYcash, WyecBridge} from "../contracts/WyecBridge.sol";
import {WrappedYcash} from "../contracts/WrappedYcash.sol";
import {BridgeTestBase} from "./utils/BridgeTestBase.sol";

/// The per-proposer cap on open optimistic proposals (audit W3-B-3).
contract ProposalCapTest is BridgeTestBase {
    uint256 constant AMOUNT = 1e8;

    function setUp() public override {
        super.setUp();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        bridge = new WyecBridge(IWrappedYcash(predicted), guardianAddrs, 2, WINDOW, 0, 0, 2, NO_PREDECESSOR);
        token = new WrappedYcash(address(bridge));
    }

    function lockN(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("cap-lock", n));
    }

    function test_Propose_OpenCapPerProposer() public {
        propose(guardianKeys[0], lockN(1), AMOUNT, alice);
        propose(guardianKeys[0], lockN(2), AMOUNT, alice);
        assertEq(bridge.openProposals(guardianAddrs[0]), 2);
        bytes memory sig = sign(guardianKeys[0], mintDigest(address(bridge), lockN(3), AMOUNT, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.TooManyOpenProposals.selector, guardianAddrs[0], 2));
        bridge.proposeMint(lockN(3), AMOUNT, alice, sig);

        propose(guardianKeys[1], lockN(3), AMOUNT, alice);
        assertEq(bridge.openProposals(guardianAddrs[1]), 1);

        challenge(guardianKeys[1], lockN(1), 1);
        assertEq(bridge.openProposals(guardianAddrs[0]), 1);
        propose(guardianKeys[0], lockN(3 + 100), AMOUNT, alice);
        assertEq(bridge.openProposals(guardianAddrs[0]), 2);
    }

    function test_OpenCount_ExecuteChallengeMintAndVoidReplace() public {
        propose(guardianKeys[0], lockN(1), AMOUNT, alice); // executed
        propose(guardianKeys[0], lockN(2), AMOUNT, alice); // cleared by threshold mint
        assertEq(bridge.openProposals(guardianAddrs[0]), 2);

        vm.warp(block.timestamp + WINDOW);
        bridge.executeMint(lockN(1));
        assertEq(bridge.openProposals(guardianAddrs[0]), 1);
        mintTo(alice, AMOUNT, lockN(2));
        assertEq(bridge.openProposals(guardianAddrs[0]), 0);

        propose(guardianKeys[0], lockN(3), AMOUNT, alice);
        assertEq(bridge.openProposals(guardianAddrs[0]), 1);
        address[] memory g = new address[](2);
        g[0] = guardianAddrs[1];
        g[1] = guardianAddrs[2];
        setGuardians(g, 2);
        propose(guardianKeys[1], lockN(3), AMOUNT, alice);
        assertEq(bridge.openProposals(guardianAddrs[0]), 0);
        assertEq(bridge.openProposals(guardianAddrs[1]), 1);

        challenge(guardianKeys[2], lockN(3), bridge.proposalCount());
        assertEq(bridge.openProposals(guardianAddrs[1]), 0);
    }

    function test_Constructor_MainnetRequiresOpenCap() public {
        IWrappedYcash t = IWrappedYcash(address(token));
        vm.chainId(1);
        vm.expectRevert(WyecBridge.MainnetOpenProposalCapRequired.selector);
        new WyecBridge(t, guardianAddrs, 2, 2 hours, 5e8, 1 days, 0, NO_PREDECESSOR);
    }
}
