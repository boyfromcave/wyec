// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IWrappedYcash, IWyecBridgeConsumed, WyecBridge} from "../contracts/WyecBridge.sol";
import {WrappedYcash} from "../contracts/WrappedYcash.sol";
import {WyecEip712} from "./utils/WyecEip712.sol";

/// Drives propose / challenge / execute / threshold mint / rotation / time over a small lockId
/// space, so void proposals (proposer rotated out) and their replacement occur.
contract ProposalCapHandler is Test {
    WyecBridge public immutable bridge;
    uint256[4] internal pks = [uint256(0xA11CE), 0xB0B, 0xCA401, 0xD00D];
    /// Indices into `pks` of the current guardian set (always two or more).
    uint256[] internal current;
    uint256 public constant LOCKS = 12;
    /// Advances on every mint, so fresh lockIds keep coming.
    uint256 internal base;
    /// Every lockId a proposal was opened for (the invariant scans these).
    bytes32[] public touched;
    mapping(bytes32 => bool) internal seen;
    /// Ghosts: successful proposals, and proposals refused at the cap.
    uint256 public opened;
    uint256 public capped;

    constructor(WyecBridge b) {
        bridge = b;
        current.push(0);
        current.push(1);
        current.push(2);
    }

    function addr(uint256 i) public view returns (address) {
        return vm.addr(pks[i]);
    }

    function lock(uint256 i) public view returns (bytes32) {
        return keccak256(abi.encode("inv-lock", base + (i % LOCKS)));
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    function sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function domain() internal view returns (bytes32) {
        return WyecEip712.domainSeparator(block.chainid, address(bridge));
    }

    /// Two current guardians' signatures over `digest`, ascending by address.
    function pair(bytes32 digest) internal view returns (bytes[] memory s) {
        uint256 a = pks[current[0]];
        uint256 b = pks[current[1]];
        if (vm.addr(a) > vm.addr(b)) (a, b) = (b, a);
        s = new bytes[](2);
        s[0] = sig(a, digest);
        s[1] = sig(b, digest);
    }

    function propose(uint256 who, uint256 l) external {
        bytes32 id = lock(l);
        bytes32 d = WyecEip712.digest(domain(), WyecEip712.mintStruct(id, 1e8, address(0xA1)));
        try bridge.proposeMint(id, 1e8, address(0xA1), sig(pks[who % 4], d)) {
            opened++;
            if (!seen[id]) {
                seen[id] = true;
                touched.push(id);
            }
        } catch (bytes memory err) {
            if (bytes4(err) == WyecBridge.TooManyOpenProposals.selector) capped++;
        }
    }

    function challenge(uint256 who, uint256 l) external {
        bytes32 id = lock(l);
        uint256 pid = bridge.getProposal(id).id;
        bytes32 d = WyecEip712.digest(domain(), WyecEip712.challengeStruct(id, pid));
        try bridge.challengeMint(id, pid, sig(pks[who % 4], d)) {} catch {}
    }

    function execute(uint256 l) external {
        try bridge.executeMint(lock(l)) {
            base++;
        } catch {}
    }

    function thresholdMint(uint256 l) external {
        bytes32 id = lock(l);
        bytes32 d = WyecEip712.digest(domain(), WyecEip712.mintStruct(id, 1e8, address(0xA1)));
        try bridge.mint(id, 1e8, address(0xA1), pair(d)) {
            base++;
        } catch {}
    }

    /// Rotates to a set of two to four of the four keys (a non-empty mask bit pattern).
    function rotate(uint256 seed) external {
        uint256 mask = seed % 16;
        uint256 n;
        for (uint256 i = 0; i < 4; i++) {
            if (mask & (1 << i) != 0) n++;
        }
        if (n < 2) return;
        address[] memory g = new address[](n);
        uint256[] memory next = new uint256[](n);
        uint256 k;
        for (uint256 i = 0; i < 4; i++) {
            if (mask & (1 << i) != 0) {
                g[k] = addr(i);
                next[k++] = i;
            }
        }
        bytes32 d = WyecEip712.digest(domain(), WyecEip712.setGuardiansStruct(g, 2, bridge.adminNonce()));
        bridge.setGuardians(g, 2, pair(d));
        delete current;
        for (uint256 i = 0; i < n; i++) {
            current.push(next[i]);
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + (dt % 2 hours));
    }
}

/// W3-B-3: `openProposals[a]` always equals the number of lockIds whose proposal has proposer `a`,
/// and never exceeds `maxOpenProposals`.
contract ProposalCapInvariantTest is Test {
    uint256 constant CAP = 2;
    WyecBridge bridge;
    ProposalCapHandler handler;

    function setUp() public {
        vm.warp(1_760_000_000);
        address[] memory g = new address[](3);
        g[0] = vm.addr(0xA11CE);
        g[1] = vm.addr(0xB0B);
        g[2] = vm.addr(0xCA401);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        bridge =
            new WyecBridge(IWrappedYcash(predicted), g, 2, 3600, 0, 0, CAP, IWyecBridgeConsumed(address(0)));
        new WrappedYcash(address(bridge));
        handler = new ProposalCapHandler(bridge);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_OpenCountMatchesProposals() public view {
        for (uint256 i = 0; i < 4; i++) {
            address a = handler.addr(i);
            uint256 n;
            for (uint256 l = 0; l < handler.touchedCount(); l++) {
                WyecBridge.Proposal memory p = bridge.getProposal(handler.touched(l));
                if (p.id != 0 && p.proposer == a) n++;
            }
            assertEq(bridge.openProposals(a), n, "open count");
            assertLe(n, CAP, "cap");
        }
    }

    /// The handler reaches the cap and opens proposals (the invariant is not vacuous).
    function afterInvariant() public {
        emit log_named_uint("proposals opened", handler.opened());
        emit log_named_uint("refused at the cap", handler.capped());
    }
}
