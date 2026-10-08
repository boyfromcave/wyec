// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {WrappedYcash} from "../contracts/WrappedYcash.sol";
import {IWrappedYcash, WyecBridge} from "../contracts/WyecBridge.sol";
import {BridgeTestBase} from "./utils/BridgeTestBase.sol";
import {WyecEip712} from "./utils/WyecEip712.sol";

/// The threshold (fast) path, burn, pause, rotation, hand-off and the token: every behaviour of the
/// pre-CR-W1 bridge, unchanged (the Hawkeye plan's HK-11 facts among them).
contract WyecBridgeTest is BridgeTestBase {
    bytes32 constant LOCK = keccak256("lock-1");
    uint256 constant AMOUNT = 5e8;

    // ------------------------------------------------------------------ deployment

    function test_DeployOrder_PredictedTokenAddress() public view {
        assertEq(address(bridge.token()), address(token));
        assertEq(token.bridge(), address(bridge));
        assertEq(bridge.threshold(), 2);
        assertEq(bridge.guardianCount(), 3);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(bridge.guardians(i), guardianAddrs[i]);
            assertTrue(bridge.isGuardian(guardianAddrs[i]));
        }
    }

    function test_Eip712Domain_IsWyecBridgeV1() public view {
        (, string memory name, string memory version, uint256 chainId, address vc,,) = bridge.eip712Domain();
        assertEq(name, "WyecBridge");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(vc, address(bridge));
    }

    function test_Token_Decimals8_Cap21M() public view {
        assertEq(token.decimals(), 8);
        assertEq(token.CAP(), 21_000_000 * 1e8);
        assertEq(token.cap(), 21_000_000 * 1e8);
        assertEq(token.name(), "Wrapped Ycash");
        assertEq(token.symbol(), "wYEC");
        assertEq(token.totalSupply(), 0);
    }

    function test_BadGuardianSet_Rejected() public {
        address[] memory g = new address[](2);
        g[0] = address(1);
        g[1] = address(2);
        vm.expectRevert(WyecBridge.BadGuardianSet.selector);
        new WyecBridge(IWrappedYcash(address(token)), g, 0, WINDOW, 0, 0);
        vm.expectRevert(WyecBridge.BadGuardianSet.selector);
        new WyecBridge(IWrappedYcash(address(token)), g, 3, WINDOW, 0, 0);
        g[1] = address(1);
        vm.expectRevert(WyecBridge.BadGuardianSet.selector);
        new WyecBridge(IWrappedYcash(address(token)), g, 1, WINDOW, 0, 0);
        g[1] = address(0);
        vm.expectRevert(WyecBridge.BadGuardianSet.selector);
        new WyecBridge(IWrappedYcash(address(token)), g, 1, WINDOW, 0, 0);
    }

    function test_Constructor_ParamsAndEvents() public {
        address[] memory g = new address[](1);
        g[0] = address(1);
        vm.expectEmit(false, false, false, true);
        emit GuardiansChanged(g, 1);
        vm.expectEmit(false, false, false, true);
        emit MintLimitChanged(5e8, 60);
        WyecBridge b = new WyecBridge(IWrappedYcash(address(token)), g, 1, 77, 5e8, 60);
        assertEq(b.challengeWindow(), 77);
        assertEq(b.mintCap(), 5e8);
        assertEq(b.capWindow(), 60);
        assertEq(b.mintAvailable(), 5e8);
        assertEq(b.proposalCount(), 0);
        assertEq(bridge.mintCap(), 0);
        assertEq(bridge.mintAvailable(), type(uint256).max);
    }

    function test_Constructor_ZeroChallengeWindowRejected() public {
        vm.expectRevert(WyecBridge.ZeroChallengeWindow.selector);
        new WyecBridge(IWrappedYcash(address(token)), guardianAddrs, 2, 0, 0, 0);
    }

    function test_Constructor_CapWithoutWindowRejected() public {
        vm.expectRevert(WyecBridge.BadMintLimit.selector);
        new WyecBridge(IWrappedYcash(address(token)), guardianAddrs, 2, WINDOW, 1, 0);
        // No cap: the window is irrelevant and may be zero (or anything).
        new WyecBridge(IWrappedYcash(address(token)), guardianAddrs, 2, WINDOW, 0, 0);
    }

    /// The contract's digest helpers agree with the independent encoding in WyecEip712.
    function test_DigestViews_MatchIndependentEncoding() public view {
        bytes32 lock = keccak256("x");
        assertEq(bridge.mintDigest(lock, 3, alice), mintDigest(address(bridge), lock, 3, alice));
        assertEq(bridge.challengeDigest(lock, 9), challengeDigest(address(bridge), lock, 9));
    }

    // ------------------------------------------------------------------ mint

    function test_Mint_TwoOfThree() public {
        vm.expectEmit(true, true, false, true, address(bridge));
        emit Minted(LOCK, alice, AMOUNT);
        mintTo(alice, AMOUNT, LOCK);
        assertEq(token.balanceOf(alice), AMOUNT);
        assertEq(token.totalSupply(), AMOUNT);
        assertTrue(bridge.consumed(LOCK));
    }

    function test_Mint_AllThreeSigsAccepted() public {
        bytes[] memory sigs = signSorted(guardianKeys, mintDigest(address(bridge), LOCK, AMOUNT, alice));
        bridge.mint(LOCK, AMOUNT, alice, sigs);
        assertEq(token.balanceOf(alice), AMOUNT);
    }

    function test_Mint_OneOfOne() public {
        address[] memory g = new address[](1);
        g[0] = guardianAddrs[0];
        (WrappedYcash t, WyecBridge b) = deployPair(g, 1);
        b.mint(
            LOCK,
            AMOUNT,
            alice,
            signSorted(keys(guardianKeys[0]), mintDigest(address(b), LOCK, AMOUNT, alice))
        );
        assertEq(t.balanceOf(alice), AMOUNT);
    }

    function test_Mint_AnyoneMaySubmit() public {
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), LOCK, AMOUNT, alice));
        vm.prank(bob);
        bridge.mint(LOCK, AMOUNT, alice, sigs);
        assertEq(token.balanceOf(alice), AMOUNT);
    }

    function test_Mint_LockIdReplayRejected() public {
        mintTo(alice, AMOUNT, LOCK);
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), LOCK, AMOUNT, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.LockConsumed.selector, LOCK));
        bridge.mint(LOCK, AMOUNT, alice, sigs);
        // Also with different fields: the lockId alone is the replay key.
        sigs = signSorted(guardianPair(), mintDigest(address(bridge), LOCK, 1, bob));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.LockConsumed.selector, LOCK));
        bridge.mint(LOCK, 1, bob, sigs);
    }

    function test_Mint_SignersMustBeStrictlyAscending() public {
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), LOCK, AMOUNT, alice));
        (sigs[0], sigs[1]) = (sigs[1], sigs[0]);
        vm.expectRevert(WyecBridge.SignersNotAscending.selector);
        bridge.mint(LOCK, AMOUNT, alice, sigs);
    }

    function test_Mint_DuplicateSignatureRejected() public {
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sign(guardianKeys[0], mintDigest(address(bridge), LOCK, AMOUNT, alice));
        sigs[1] = sigs[0];
        vm.expectRevert(WyecBridge.SignersNotAscending.selector);
        bridge.mint(LOCK, AMOUNT, alice, sigs);
    }

    function test_Mint_NonGuardianRejected() public {
        uint256[] memory ks = keys(guardianKeys[0], outsiderKey);
        bytes[] memory sigs = signSorted(ks, mintDigest(address(bridge), LOCK, AMOUNT, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NotGuardian.selector, vm.addr(outsiderKey)));
        bridge.mint(LOCK, AMOUNT, alice, sigs);
    }

    function test_Mint_BelowThresholdRejected() public {
        bytes[] memory sigs =
            signSorted(keys(guardianKeys[0]), mintDigest(address(bridge), LOCK, AMOUNT, alice));
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.Threshold.selector, 1, 2));
        bridge.mint(LOCK, AMOUNT, alice, sigs);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.Threshold.selector, 0, 2));
        bridge.mint(LOCK, AMOUNT, alice, new bytes[](0));
    }

    /// Amount and recipient are inside the signed struct: a submitter cannot alter them.
    function test_Mint_TamperedFieldsRejected() public {
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), LOCK, AMOUNT, alice));
        vm.expectRevert();
        bridge.mint(LOCK, AMOUNT + 1, alice, sigs);
        vm.expectRevert();
        bridge.mint(LOCK, AMOUNT, bob, sigs);
        vm.expectRevert();
        bridge.mint(keccak256("other"), AMOUNT, alice, sigs);
        assertFalse(bridge.consumed(LOCK));
    }

    /// The domain binds the bridge address: a signature for another deployment does not verify.
    function test_Mint_OtherDeploymentSignatureRejected() public {
        (, WyecBridge other) = deployPair(guardianAddrs, 2);
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(other), LOCK, AMOUNT, alice));
        vm.expectRevert();
        bridge.mint(LOCK, AMOUNT, alice, sigs);
    }

    /// OpenZeppelin ECDSA rejects high-S: signers must emit low-S signatures.
    function test_Mint_HighSRejected() public {
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        address[] memory g = new address[](1);
        g[0] = guardianAddrs[0];
        (, WyecBridge b) = deployPair(g, 1);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(guardianKeys[0], mintDigest(address(b), LOCK, AMOUNT, alice));
        assertLe(uint256(s), n / 2, "vm.sign is low-S");
        // The same signature with s -> n - s and the parity flipped recovers the same key.
        bytes32 hs = bytes32(n - uint256(s));
        uint8 hv = v == 27 ? 28 : 27;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, hs, hv);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, hs));
        b.mint(LOCK, AMOUNT, alice, sigs);
        sigs[0] = abi.encodePacked(r, s, v);
        b.mint(LOCK, AMOUNT, alice, sigs);
    }

    /// A lock whose destination decodes to address(0) can never mint (the token refuses), so the
    /// lock policy must refuse it before signing; the reverted mint leaves the lockId unconsumed.
    function test_Mint_ToZeroAddressReverts() public {
        bytes[] memory sigs =
            signSorted(guardianPair(), mintDigest(address(bridge), LOCK, AMOUNT, address(0)));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        bridge.mint(LOCK, AMOUNT, address(0), sigs);
        assertFalse(bridge.consumed(LOCK));
    }

    function test_Mint_CapEnforced() public {
        uint256 cap = token.CAP();
        mintTo(alice, cap, LOCK);
        bytes32 lock2 = keccak256("lock-2");
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), lock2, 1, alice));
        vm.expectRevert(abi.encodeWithSelector(ERC20Capped.ERC20ExceededCap.selector, cap + 1, cap));
        bridge.mint(lock2, 1, alice, sigs);
        assertFalse(bridge.consumed(lock2));
    }

    function test_Token_OnlyBridgeMintsAndBurns() public {
        vm.expectRevert(abi.encodeWithSelector(WrappedYcash.NotBridge.selector, address(this)));
        token.crosschainMint(alice, 1);
        mintTo(alice, AMOUNT, LOCK);
        vm.expectRevert(abi.encodeWithSelector(WrappedYcash.NotBridge.selector, alice));
        vm.prank(alice);
        token.crosschainBurn(alice, 1);
    }

    // ------------------------------------------------------------------ burn

    function test_Burn_EventFieldsAndNonceIncrements() public {
        mintTo(alice, AMOUNT, LOCK);
        bytes32 r1 = bytes32(uint256(0x0100) << 240 | uint256(uint160(address(0xAbCd))));
        bytes32 r2 = keccak256("arbitrary-opaque-recipient");
        assertEq(bridge.burnNonce(), 0);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit BurnToYcash(0, alice, 1e8, r1);
        vm.prank(alice);
        bridge.burn(1e8, r1);
        assertEq(bridge.burnNonce(), 1);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit BurnToYcash(1, alice, 2e8, r2);
        vm.prank(alice);
        bridge.burn(2e8, r2);
        assertEq(bridge.burnNonce(), 2);
        assertEq(token.balanceOf(alice), AMOUNT - 3e8);
        assertEq(token.totalSupply(), AMOUNT - 3e8);
    }

    /// BurnToYcash topics: [sig, nonce, from]; data: abi.encode(amount, ycashRecipient).
    function test_Burn_LogLayout() public {
        mintTo(alice, AMOUNT, LOCK);
        bytes32 rcpt = keccak256("r");
        vm.recordLogs();
        vm.prank(alice);
        bridge.burn(7, rcpt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory l = logs[logs.length - 1];
        assertEq(l.emitter, address(bridge));
        assertEq(l.topics.length, 3);
        assertEq(l.topics[0], keccak256("BurnToYcash(uint256,address,uint256,bytes32)"));
        assertEq(l.topics[1], bytes32(uint256(0)));
        assertEq(l.topics[2], bytes32(uint256(uint160(alice))));
        assertEq(l.data, abi.encode(uint256(7), rcpt));
    }

    function test_Burn_NeedsNoAllowance() public {
        mintTo(alice, AMOUNT, LOCK);
        assertEq(token.allowance(alice, address(bridge)), 0);
        vm.prank(alice);
        bridge.burn(AMOUNT, bytes32(0));
        assertEq(token.balanceOf(alice), 0);
    }

    function test_Burn_MoreThanBalanceReverts() public {
        mintTo(alice, AMOUNT, LOCK);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, AMOUNT, AMOUNT + 1)
        );
        vm.prank(alice);
        bridge.burn(AMOUNT + 1, bytes32(0));
        assertEq(bridge.burnNonce(), 0);
    }

    /// The contract accepts a zero-amount burn and spends a nonce on it: the daemon must treat such
    /// a burn as orphaned (nothing to release), never as a gap in the nonce sequence.
    function test_Burn_ZeroAmountConsumesNonce() public {
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BurnToYcash(0, bob, 0, bytes32(0));
        vm.prank(bob);
        bridge.burn(0, bytes32(0));
        assertEq(bridge.burnNonce(), 1);
    }

    // ------------------------------------------------------------------ pause

    function test_Pause_StopsMintAndBurnNotTransfers() public {
        mintTo(alice, AMOUNT, LOCK);
        bridge.setPaused(true, signedSetPaused(true));
        assertTrue(bridge.paused());
        assertEq(bridge.adminNonce(), 1);

        bytes32 lock2 = keccak256("lock-2");
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), lock2, 1, alice));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.mint(lock2, 1, alice, sigs);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        bridge.burn(1, bytes32(0));

        vm.prank(alice);
        assertTrue(token.transfer(bob, 1e8));
        assertEq(token.balanceOf(bob), 1e8);

        bridge.setPaused(false, signedSetPaused(false));
        assertFalse(bridge.paused());
        assertEq(bridge.adminNonce(), 2);
        bridge.mint(lock2, 1, alice, sigs); // signed while paused, still valid after
        vm.prank(alice);
        bridge.burn(1, bytes32(0));
    }

    /// setPaused to the current state reverts (OpenZeppelin Pausable) and spends no adminNonce:
    /// a pause signature collected while another pause lands is dead, not reusable later.
    function test_Pause_NoOpReverts() public {
        bytes[] memory sigs = signedSetPaused(false);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        bridge.setPaused(false, sigs);
        assertEq(bridge.adminNonce(), 0);
        bridge.setPaused(true, signedSetPaused(true));
        sigs = signedSetPaused(true);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.setPaused(true, sigs);
        assertEq(bridge.adminNonce(), 1);
    }

    function test_Pause_ReplayOfAdminSigsRejected() public {
        bytes[] memory sigs = signedSetPaused(true);
        bridge.setPaused(true, sigs);
        vm.expectRevert(); // adminNonce moved: the old digest recovers to non-guardians
        bridge.setPaused(true, sigs);
    }

    // ------------------------------------------------------------------ rotation

    function test_SetGuardians_RotationAndAdminNonce() public {
        uint256 newKey = 0xD00D;
        address[] memory g = new address[](3);
        g[0] = guardianAddrs[1];
        g[1] = guardianAddrs[2];
        g[2] = vm.addr(newKey);
        uint256 nonce = bridge.adminNonce();
        bytes32 d = WyecEip712.digest(domainOf(address(bridge)), WyecEip712.setGuardiansStruct(g, 3, nonce));

        vm.expectEmit(false, false, false, true, address(bridge));
        emit GuardiansChanged(g, 3);
        bridge.setGuardians(g, 3, signSorted(guardianPair(), d));

        assertEq(bridge.adminNonce(), nonce + 1);
        assertEq(bridge.threshold(), 3);
        assertEq(bridge.guardianCount(), 3);
        assertFalse(bridge.isGuardian(guardianAddrs[0]));
        assertTrue(bridge.isGuardian(vm.addr(newKey)));

        // The removed guardian's signature no longer counts; the new set's does.
        uint256[] memory oldSet = new uint256[](3);
        oldSet[0] = guardianKeys[0];
        oldSet[1] = guardianKeys[1];
        oldSet[2] = guardianKeys[2];
        bytes32 md = mintDigest(address(bridge), LOCK, AMOUNT, alice);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.NotGuardian.selector, guardianAddrs[0]));
        bridge.mint(LOCK, AMOUNT, alice, signSorted(oldSet, md));

        uint256[] memory newSet = new uint256[](3);
        newSet[0] = guardianKeys[1];
        newSet[1] = guardianKeys[2];
        newSet[2] = newKey;
        bridge.mint(LOCK, AMOUNT, alice, signSorted(newSet, md));
        assertEq(token.balanceOf(alice), AMOUNT);
    }

    /// Mint signatures carry no nonce: one made before a rotation stays valid after it as long as
    /// its signers are still guardians (the lockId is the only replay key).
    function test_SetGuardians_MintSigsSurviveRotationOfOthers() public {
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), LOCK, AMOUNT, alice));
        address[] memory g = new address[](2);
        g[0] = guardianAddrs[0];
        g[1] = guardianAddrs[1];
        bytes32 d = WyecEip712.digest(
            domainOf(address(bridge)), WyecEip712.setGuardiansStruct(g, 2, bridge.adminNonce())
        );
        bridge.setGuardians(g, 2, signSorted(guardianPair(), d));
        bridge.mint(LOCK, AMOUNT, alice, sigs);
    }

    function test_SetGuardians_WorksWhilePaused() public {
        bridge.setPaused(true, signedSetPaused(true));
        address[] memory g = new address[](1);
        g[0] = guardianAddrs[2];
        bytes32 d = WyecEip712.digest(
            domainOf(address(bridge)), WyecEip712.setGuardiansStruct(g, 1, bridge.adminNonce())
        );
        bridge.setGuardians(g, 1, signSorted(guardianPair(), d));
        assertEq(bridge.adminNonce(), 2);
        assertEq(bridge.guardianCount(), 1);
    }

    function test_SetGuardians_BadSetRejected() public {
        address[] memory g = new address[](1);
        g[0] = guardianAddrs[0];
        bytes32 d = WyecEip712.digest(
            domainOf(address(bridge)), WyecEip712.setGuardiansStruct(g, 2, bridge.adminNonce())
        );
        bytes[] memory sigs = signSorted(guardianPair(), d);
        vm.expectRevert(WyecBridge.BadGuardianSet.selector);
        bridge.setGuardians(g, 2, sigs);
        assertEq(bridge.adminNonce(), 0); // the whole call reverted, nonce included
    }

    // ------------------------------------------------------------------ bridge handoff

    function test_SetBridge_Handoff() public {
        mintTo(alice, AMOUNT, LOCK);
        address successor = makeAddr("successor");
        bytes32 d = WyecEip712.digest(
            domainOf(address(bridge)), WyecEip712.setBridgeStruct(successor, bridge.adminNonce())
        );
        vm.expectEmit(true, true, false, false, address(token));
        emit BridgeChanged(address(bridge), successor);
        bridge.setBridge(successor, signSorted(guardianPair(), d));
        assertEq(token.bridge(), successor);
        assertEq(bridge.adminNonce(), 1);

        // The old bridge can no longer mint or burn.
        bytes32 lock2 = keccak256("lock-2");
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(bridge), lock2, 1, alice));
        vm.expectRevert(abi.encodeWithSelector(WrappedYcash.NotBridge.selector, address(bridge)));
        bridge.mint(lock2, 1, alice, sigs);
        vm.expectRevert(abi.encodeWithSelector(WrappedYcash.NotBridge.selector, address(bridge)));
        vm.prank(alice);
        bridge.burn(1, bytes32(0));

        // The successor mints directly; balances are untouched.
        vm.prank(successor);
        token.crosschainMint(bob, 3);
        assertEq(token.balanceOf(bob), 3);
        assertEq(token.balanceOf(alice), AMOUNT);
    }

    function test_SetBridge_ZeroRejected() public {
        bytes32 d = WyecEip712.digest(
            domainOf(address(bridge)), WyecEip712.setBridgeStruct(address(0), bridge.adminNonce())
        );
        bytes[] memory sigs = signSorted(guardianPair(), d);
        vm.expectRevert(WrappedYcash.ZeroBridge.selector);
        bridge.setBridge(address(0), sigs);
    }

    /// One adminNonce is shared by setGuardians, setPaused and setBridge.
    function test_AdminNonce_SharedAcrossActs() public {
        bridge.setPaused(true, signedSetPaused(true));
        bytes32 d =
            WyecEip712.digest(domainOf(address(bridge)), WyecEip712.setGuardiansStruct(guardianAddrs, 2, 1));
        bridge.setGuardians(guardianAddrs, 2, signSorted(guardianPair(), d));
        assertEq(bridge.adminNonce(), 2);
        bridge.setPaused(false, signedSetPaused(false));
        assertEq(bridge.adminNonce(), 3);
    }
}
