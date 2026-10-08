// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WrappedYcash} from "../../contracts/WrappedYcash.sol";
import {IWrappedYcash, WyecBridge} from "../../contracts/WyecBridge.sol";
import {WyecEip712} from "./WyecEip712.sol";

/// Shared fixture: a token + bridge deployed in the order of wyec-contract-design.md §8 (bridge
/// first at the predicted token address), three guardians, threshold 2, a one-hour challenge
/// window and no rate limit; signing helpers for every EIP-712 struct.
abstract contract BridgeTestBase is Test {
    uint64 internal constant WINDOW = 3600;

    WrappedYcash internal token;
    WyecBridge internal bridge;

    uint256[] internal guardianKeys;
    address[] internal guardianAddrs;
    uint256 internal outsiderKey = 0xBAD;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // Events, redeclared for vm.expectEmit.
    event Minted(bytes32 indexed lockId, address indexed to, uint256 amount);
    event BurnToYcash(uint256 indexed nonce, address indexed from, uint256 amount, bytes32 ycashRecipient);
    event GuardiansChanged(address[] guardians, uint8 threshold);
    event MintLimitChanged(uint256 mintCap, uint256 capWindow);
    event MintProposed(
        bytes32 indexed lockId,
        uint256 indexed proposalId,
        address indexed proposer,
        address to,
        uint256 amount,
        uint64 eta
    );
    event MintChallenged(bytes32 indexed lockId, uint256 indexed proposalId, address indexed challenger);
    event BridgeChanged(address indexed previousBridge, address indexed newBridge);

    function setUp() public virtual {
        guardianKeys.push(0xA11CE);
        guardianKeys.push(0xB0B);
        guardianKeys.push(0xCA401);
        for (uint256 i = 0; i < guardianKeys.length; i++) {
            guardianAddrs.push(vm.addr(guardianKeys[i]));
        }
        (token, bridge) = deployPair(guardianAddrs, 2);
        vm.warp(1_760_000_000); // a realistic clock, so window indices are not 0
    }

    function deployPair(address[] memory guardians, uint8 threshold)
        internal
        returns (WrappedYcash t, WyecBridge b)
    {
        return deployPair(guardians, threshold, WINDOW, 0, 0);
    }

    function deployPair(
        address[] memory guardians,
        uint8 threshold,
        uint64 challengeWindow,
        uint256 mintCap,
        uint256 capWindow
    ) internal returns (WrappedYcash t, WyecBridge b) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        b = new WyecBridge(
            IWrappedYcash(predicted), guardians, threshold, challengeWindow, mintCap, capWindow
        );
        t = new WrappedYcash(address(b));
        assertEq(address(t), predicted, "token prediction");
    }

    // ------------------------------------------------------------------ signing

    function domainOf(address b) internal view returns (bytes32) {
        return WyecEip712.domainSeparator(block.chainid, b);
    }

    function sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function mintDigest(address b, bytes32 lockId, uint256 amount, address to)
        internal
        view
        returns (bytes32)
    {
        return WyecEip712.digest(domainOf(b), WyecEip712.mintStruct(lockId, amount, to));
    }

    function challengeDigest(address b, bytes32 lockId, uint256 proposalId) internal view returns (bytes32) {
        return WyecEip712.digest(domainOf(b), WyecEip712.challengeStruct(lockId, proposalId));
    }

    /// Signatures by `pks`, ordered by ascending signer address (the contract's rule).
    function signSorted(uint256[] memory pks, bytes32 digest) internal pure returns (bytes[] memory sigs) {
        uint256[] memory ks = sortByAddress(pks);
        sigs = new bytes[](ks.length);
        for (uint256 i = 0; i < ks.length; i++) {
            sigs[i] = sign(ks[i], digest);
        }
    }

    function sortByAddress(uint256[] memory pks) internal pure returns (uint256[] memory ks) {
        ks = new uint256[](pks.length);
        for (uint256 i = 0; i < pks.length; i++) {
            ks[i] = pks[i];
        }
        for (uint256 i = 1; i < ks.length; i++) {
            for (uint256 j = i; j > 0 && vm.addr(ks[j - 1]) > vm.addr(ks[j]); j--) {
                (ks[j - 1], ks[j]) = (ks[j], ks[j - 1]);
            }
        }
    }

    function keys(uint256 a, uint256 b) internal pure returns (uint256[] memory ks) {
        ks = new uint256[](2);
        ks[0] = a;
        ks[1] = b;
    }

    function keys(uint256 a) internal pure returns (uint256[] memory ks) {
        ks = new uint256[](1);
        ks[0] = a;
    }

    function guardianPair() internal view returns (uint256[] memory) {
        return keys(guardianKeys[0], guardianKeys[1]);
    }

    // ------------------------------------------------------------------ acts

    /// Mint through the threshold path with two guardian signatures.
    function mintTo(address to, uint256 amount, bytes32 lockId) internal {
        bridge.mint(
            lockId, amount, to, signSorted(guardianPair(), mintDigest(address(bridge), lockId, amount, to))
        );
    }

    /// Propose a mint with guardian `pk`'s single signature; returns the proposal id.
    function propose(uint256 pk, bytes32 lockId, uint256 amount, address to) internal returns (uint256) {
        return
            bridge.proposeMint(lockId, amount, to, sign(pk, mintDigest(address(bridge), lockId, amount, to)));
    }

    function challenge(uint256 pk, bytes32 lockId, uint256 proposalId) internal {
        bridge.challengeMint(
            lockId, proposalId, sign(pk, challengeDigest(address(bridge), lockId, proposalId))
        );
    }

    function signedSetPaused(bool paused) internal view returns (bytes[] memory) {
        bytes32 d = WyecEip712.digest(
            domainOf(address(bridge)), WyecEip712.setPausedStruct(paused, bridge.adminNonce())
        );
        return signSorted(guardianPair(), d);
    }

    function signedSetMintLimit(uint256 mintCap, uint256 capWindow) internal view returns (bytes[] memory) {
        bytes32 d = WyecEip712.digest(
            domainOf(address(bridge)), WyecEip712.setMintLimitStruct(mintCap, capWindow, bridge.adminNonce())
        );
        return signSorted(guardianPair(), d);
    }

    function setMintLimit(uint256 mintCap, uint256 capWindow) internal {
        bridge.setMintLimit(mintCap, capWindow, signedSetMintLimit(mintCap, capWindow));
    }

    /// Rotates to (g, k), signed by guardians 0 and 1.
    function setGuardians(address[] memory g, uint8 k) internal {
        setGuardians(g, k, guardianPair());
    }

    function setGuardians(address[] memory g, uint8 k, uint256[] memory signers) internal {
        bytes32 d = WyecEip712.digest(
            domainOf(address(bridge)), WyecEip712.setGuardiansStruct(g, k, bridge.adminNonce())
        );
        bridge.setGuardians(g, k, signSorted(signers, d));
    }
}
