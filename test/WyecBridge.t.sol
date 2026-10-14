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
        new WyecBridge(IWrappedYcash(address(token)), g, 0, WINDOW, 0, 0, 0, NO_PREDECESSOR);
        vm.expectRevert(WyecBridge.BadGuardianSet.selector);
        new WyecBridge(IWrappedYcash(address(token)), g, 3, WINDOW, 0, 0, 0, NO_PREDECESSOR);
        g[1] = address(1);
        vm.expectRevert(WyecBridge.BadGuardianSet.selector);
        new WyecBridge(IWrappedYcash(address(token)), g, 1, WINDOW, 0, 0, 0, NO_PREDECESSOR);
        g[1] = address(0);
        vm.expectRevert(WyecBridge.BadGuardianSet.selector);
        new WyecBridge(IWrappedYcash(address(token)), g, 1, WINDOW, 0, 0, 0, NO_PREDECESSOR);
    }

    /// Mainnet (chain id 1) floors in the constructor: threshold >= 2, challengeWindow >= 2 hours,
    /// mintCap != 0; each refused by its own selector, all three met deploys. Other chains: none.
    function test_Deploy_MainnetFloors() public {
        IWrappedYcash t = IWrappedYcash(address(token));
        assertEq(bridge.MIN_MAINNET_CHALLENGE_WINDOW(), 2 hours);
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.MainnetChallengeWindow.selector, uint64(1 hours)));
        new WyecBridge(t, guardianAddrs, 2, 1 hours, 5e8, 1 days, 0, NO_PREDECESSOR);
        vm.expectRevert(
            abi.encodeWithSelector(WyecBridge.MainnetChallengeWindow.selector, uint64(2 hours - 1))
        );
        new WyecBridge(t, guardianAddrs, 2, 2 hours - 1, 5e8, 1 days, 0, NO_PREDECESSOR);
        vm.expectRevert(abi.encodeWithSelector(WyecBridge.MainnetThreshold.selector, uint8(1)));
        new WyecBridge(t, guardianAddrs, 1, 2 hours, 5e8, 1 days, 0, NO_PREDECESSOR);
        vm.expectRevert(WyecBridge.MainnetMintCapRequired.selector);
        new WyecBridge(t, guardianAddrs, 2, 2 hours, 0, 0, 0, NO_PREDECESSOR);
        vm.expectRevert(WyecBridge.MainnetOpenProposalCapRequired.selector);
        new WyecBridge(t, guardianAddrs, 2, 2 hours, 5e8, 1 days, 0, NO_PREDECESSOR);
        WyecBridge b = new WyecBridge(t, guardianAddrs, 2, 2 hours, 5e8, 1 days, 32, NO_PREDECESSOR);
        assertEq(b.challengeWindow(), 2 hours);
        assertEq(b.maxOpenProposals(), 32);
        assertEq(b.mintCap(), 5e8);

        // Off mainnet the floors do not apply (tests and devnets run 60-second windows, no cap).
        vm.chainId(11155111);
        b = new WyecBridge(t, guardianAddrs, 1, 60, 0, 0, 0, NO_PREDECESSOR);
        assertEq(b.challengeWindow(), 60);
    }

    function test_Constructor_ParamsAndEvents() public {
        address[] memory g = new address[](1);
        g[0] = address(1);
        vm.expectEmit(false, false, false, true);
        emit GuardiansChanged(g, 1);
        vm.expectEmit(false, false, false, true);
        emit MintLimitChanged(5e8, 60);
        WyecBridge b = new WyecBridge(IWrappedYcash(address(token)), g, 1, 77, 5e8, 60, 0, NO_PREDECESSOR);
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
        new WyecBridge(IWrappedYcash(address(token)), guardianAddrs, 2, 0, 0, 0, 0, NO_PREDECESSOR);
    }

    function test_Constructor_CapWithoutWindowRejected() public {
        vm.expectRevert(WyecBridge.BadMintLimit.selector);
        new WyecBridge(IWrappedYcash(address(token)), guardianAddrs, 2, WINDOW, 1, 0, 0, NO_PREDECESSOR);
        // No cap: the window is irrelevant and may be zero (or anything).
        new WyecBridge(IWrappedYcash(address(token)), guardianAddrs, 2, WINDOW, 0, 0, 0, NO_PREDECESSOR);
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
        expectNotGuardian(mintDigest(address(bridge), LOCK, AMOUNT + 1, alice), sigs[0]);
        bridge.mint(LOCK, AMOUNT + 1, alice, sigs);
        expectNotGuardian(mintDigest(address(bridge), LOCK, AMOUNT, bob), sigs[0]);
        bridge.mint(LOCK, AMOUNT, bob, sigs);
        expectNotGuardian(mintDigest(address(bridge), keccak256("other"), AMOUNT, alice), sigs[0]);
        bridge.mint(keccak256("other"), AMOUNT, alice, sigs);
        assertFalse(bridge.consumed(LOCK));
    }

    /// The domain binds the bridge address: a signature for another deployment does not verify.
    function test_Mint_OtherDeploymentSignatureRejected() public {
        (, WyecBridge other) = deployPair(guardianAddrs, 2);
        bytes[] memory sigs = signSorted(guardianPair(), mintDigest(address(other), LOCK, AMOUNT, alice));
        expectNotGuardian(mintDigest(address(bridge), LOCK, AMOUNT, alice), sigs[0]);
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
        bytes memory r1 = p2pkh(bytes20(uint160(0xAbCd)));
        bytes memory r2 = pqpkh(2, keccak256("some-pq-key-hash"));
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

    /// BurnToYcash topics: [sig, nonce, from]; data: abi.encode(amount, bytes ycashRecipient), the
    /// recipient as a dynamic `bytes` (offset, length, the bytes right-padded to a word), byte for
    /// byte what was passed in.
    function test_Burn_LogLayout() public {
        mintTo(alice, AMOUNT, LOCK);
        bytes memory rcpt = pqpkh(1, keccak256("r"));
        vm.recordLogs();
        vm.prank(alice);
        bridge.burn(7, rcpt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory l = logs[logs.length - 1];
        assertEq(l.emitter, address(bridge));
        assertEq(l.topics.length, 3);
        assertEq(l.topics[0], keccak256("BurnToYcash(uint256,address,uint256,bytes)"));
        assertEq(l.topics[1], bytes32(uint256(0)));
        assertEq(l.topics[2], bytes32(uint256(uint160(alice))));
        assertEq(l.data, abi.encode(uint256(7), rcpt));
        // Decoded back, the exact 35 bytes come out; the same for a 22-byte recipient.
        (uint256 amount, bytes memory got) = abi.decode(l.data, (uint256, bytes));
        assertEq(amount, 7);
        assertEq(got, rcpt);
        assertEq(got.length, 35);

        bytes memory rcpt22 = p2sh(bytes20(keccak256("s")));
        vm.recordLogs();
        vm.prank(alice);
        bridge.burn(1, rcpt22);
        logs = vm.getRecordedLogs();
        l = logs[logs.length - 1];
        assertEq(l.data, abi.encode(uint256(1), rcpt22));
        (, got) = abi.decode(l.data, (uint256, bytes));
        assertEq(got, rcpt22);
        assertEq(got.length, 22);
    }

    /// The ABI is `burn(uint256,bytes)`; the revision-1 `burn(uint256,bytes32)` selector no longer
    /// exists on the contract (no fallback either), so a caller built against it reverts.
    function test_Burn_SelectorIsBytesNotBytes32() public {
        assertEq(WyecBridge.burn.selector, bytes4(keccak256("burn(uint256,bytes)")));
        mintTo(alice, AMOUNT, LOCK);
        bytes4 oldSelector = bytes4(keccak256("burn(uint256,bytes32)"));
        assertTrue(oldSelector != WyecBridge.burn.selector);
        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(bridge).call(abi.encodeWithSelector(oldSelector, uint256(1), bytes32(0)));
        assertFalse(ok);
        assertEq(ret.length, 0);
        assertEq(token.balanceOf(alice), AMOUNT);
        assertEq(bridge.burnNonce(), 0);
    }

    function test_Burn_NeedsNoAllowance() public {
        mintTo(alice, AMOUNT, LOCK);
        assertEq(token.allowance(alice, address(bridge)), 0);
        vm.prank(alice);
        bridge.burn(AMOUNT, someRecipient());
        assertEq(token.balanceOf(alice), 0);
    }

    function test_Burn_MoreThanBalanceReverts() public {
        mintTo(alice, AMOUNT, LOCK);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, AMOUNT, AMOUNT + 1)
        );
        vm.prank(alice);
        bridge.burn(AMOUNT + 1, someRecipient());
        assertEq(bridge.burnNonce(), 0);
    }

    /// The contract accepts a zero-amount burn and spends a nonce on it: the daemon must treat such
    /// a burn as orphaned (nothing to release), never as a gap in the nonce sequence.
    function test_Burn_ZeroAmountConsumesNonce() public {
        bytes memory r = someRecipient();
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BurnToYcash(0, bob, 0, r);
        vm.prank(bob);
        bridge.burn(0, r);
        assertEq(bridge.burnNonce(), 1);
    }

    // ------------------------------------------------------------------ burn: recipient validation
    // Hawkeye plan §4.2 revision 2: 22 bytes `02 00|01 <hash160>` or 35 bytes `02 02 01|02 <keyHash>`.

    /// Burns `r` as alice and expects it to go through, emitting exactly `r`.
    function burnAccepted(bytes memory r) internal {
        uint256 nonce = bridge.burnNonce();
        uint256 bal = token.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BurnToYcash(nonce, alice, 1, r);
        vm.prank(alice);
        bridge.burn(1, r);
        assertEq(bridge.burnNonce(), nonce + 1);
        assertEq(token.balanceOf(alice), bal - 1);
    }

    /// Burns `r` as alice and expects `InvalidRecipient`: no burn, no nonce spent.
    function burnRejected(bytes memory r) internal {
        uint256 nonce = bridge.burnNonce();
        uint256 bal = token.balanceOf(alice);
        vm.expectRevert(WyecBridge.InvalidRecipient.selector);
        vm.prank(alice);
        bridge.burn(1, r);
        assertEq(bridge.burnNonce(), nonce);
        assertEq(token.balanceOf(alice), bal);
    }

    function test_Burn_Recipient_P2pkhAccepted() public {
        mintTo(alice, AMOUNT, LOCK);
        burnAccepted(p2pkh(bytes20(keccak256("p2pkh"))));
        burnAccepted(p2pkh(bytes20(0))); // the hash is not interpreted: all-zero is well-formed
        burnAccepted(p2pkh(bytes20(type(uint160).max)));
    }

    function test_Burn_Recipient_P2shAccepted() public {
        mintTo(alice, AMOUNT, LOCK);
        burnAccepted(p2sh(bytes20(keccak256("p2sh"))));
        burnAccepted(p2sh(bytes20(0)));
    }

    function test_Burn_Recipient_PqpkhScheme1Accepted() public {
        mintTo(alice, AMOUNT, LOCK);
        burnAccepted(pqpkh(1, keccak256("slh-dsa")));
        burnAccepted(pqpkh(1, bytes32(0)));
    }

    /// Scheme 2 (FN-DSA-512) is accepted whether or not Falcon is active on Ycash: the contract
    /// cannot know; the burner bears a release the node refuses before activation (plan §4.2).
    function test_Burn_Recipient_PqpkhScheme2Accepted() public {
        mintTo(alice, AMOUNT, LOCK);
        burnAccepted(pqpkh(2, keccak256("fn-dsa")));
        burnAccepted(pqpkh(2, bytes32(type(uint256).max)));
    }

    function test_Burn_Recipient_WrongVersionRejected() public {
        mintTo(alice, AMOUNT, LOCK);
        bytes20 h = bytes20(keccak256("h"));
        bytes32 k = keccak256("k");
        // Revision 1's version byte, and every other non-2 value, on both lengths.
        burnRejected(abi.encodePacked(bytes1(0x01), bytes1(0x00), h));
        burnRejected(abi.encodePacked(bytes1(0x00), bytes1(0x00), h));
        burnRejected(abi.encodePacked(bytes1(0x03), bytes1(0x01), h));
        burnRejected(abi.encodePacked(bytes1(0xFF), bytes1(0x00), h));
        burnRejected(abi.encodePacked(bytes1(0x01), bytes1(0x02), bytes1(0x01), k));
        burnRejected(abi.encodePacked(bytes1(0x03), bytes1(0x02), bytes1(0x02), k));
    }

    function test_Burn_Recipient_WrongKindRejected() public {
        mintTo(alice, AMOUNT, LOCK);
        bytes20 h = bytes20(keccak256("h"));
        bytes32 k = keccak256("k");
        // 22 bytes: only kinds 0 and 1; kind 2 (PQPKH) is 35 bytes, so it is wrong at 22.
        burnRejected(abi.encodePacked(bytes1(0x02), bytes1(0x02), h));
        burnRejected(abi.encodePacked(bytes1(0x02), bytes1(0x03), h));
        burnRejected(abi.encodePacked(bytes1(0x02), bytes1(0xFF), h));
        // 35 bytes: only kind 2; kinds 0 and 1 are 22 bytes, so they are wrong at 35.
        burnRejected(abi.encodePacked(bytes1(0x02), bytes1(0x00), bytes1(0x01), k));
        burnRejected(abi.encodePacked(bytes1(0x02), bytes1(0x01), bytes1(0x01), k));
        burnRejected(abi.encodePacked(bytes1(0x02), bytes1(0x03), bytes1(0x01), k));
        burnRejected(abi.encodePacked(bytes1(0x02), bytes1(0xFF), bytes1(0x02), k));
    }

    function test_Burn_Recipient_PqpkhBadSchemeRejected() public {
        mintTo(alice, AMOUNT, LOCK);
        bytes32 k = keccak256("k");
        burnRejected(pqpkh(0, k));
        burnRejected(pqpkh(3, k));
        burnRejected(pqpkh(0xFF, k));
    }

    function test_Burn_Recipient_WrongLengthRejected() public {
        mintTo(alice, AMOUNT, LOCK);
        bytes memory r22 = p2pkh(bytes20(keccak256("h")));
        bytes memory r35 = pqpkh(1, keccak256("k"));
        burnRejected(""); // empty
        burnRejected(hex"02"); // 1
        burnRejected(hex"0200"); // 2
        burnRejected(slice(r22, 21)); // 21: one byte short of P2PKH
        burnRejected(abi.encodePacked(r22, bytes1(0))); // 23: one byte over
        burnRejected(abi.encodePacked(r22, new bytes(10))); // 32: revision 1's length, well-formed prefix
        burnRejected(abi.encodePacked(bytes1(0x01), bytes1(0x00), new bytes(10), bytes20(keccak256("h")))); // 32: a revision-1 value
        burnRejected(slice(r35, 34)); // 34: one byte short of PQPKH
        burnRejected(abi.encodePacked(r35, bytes1(0))); // 36: one byte over
        burnRejected(abi.encodePacked(r35, r22)); // 57
    }

    function slice(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = b[i];
        }
    }

    /// Every 22-byte recipient with version 2 and kind 0 or 1 is accepted, whatever the hash.
    function testFuzz_Burn_Recipient_Valid22Accepted(bytes20 h, bool scriptHash) public {
        mintTo(alice, AMOUNT, LOCK);
        burnAccepted(scriptHash ? p2sh(h) : p2pkh(h));
    }

    /// Every 35-byte recipient with version 2, kind 2 and scheme 1 or 2 is accepted, whatever the key hash.
    function testFuzz_Burn_Recipient_Valid35Accepted(bytes32 k, bool falcon) public {
        mintTo(alice, AMOUNT, LOCK);
        burnAccepted(pqpkh(falcon ? 2 : 1, k));
    }

    /// No other length is accepted, whatever the content.
    function testFuzz_Burn_Recipient_OtherLengthRejected(bytes calldata r) public {
        vm.assume(r.length != 22 && r.length != 35);
        mintTo(alice, AMOUNT, LOCK);
        burnRejected(r);
    }

    /// At 22 bytes only `(0x02, 0x00|0x01)` passes; at 35 only `(0x02, 0x02, 0x01|0x02)`.
    function testFuzz_Burn_Recipient_HeaderDecides(
        uint8 version,
        uint8 kind,
        uint8 scheme,
        bytes20 h,
        bytes32 k
    ) public {
        mintTo(alice, AMOUNT, LOCK);
        bytes memory r22 = abi.encodePacked(bytes1(version), bytes1(kind), h);
        bytes memory r35 = abi.encodePacked(bytes1(version), bytes1(kind), bytes1(scheme), k);
        if (version == 2 && kind <= 1) burnAccepted(r22);
        else burnRejected(r22);
        if (version == 2 && kind == 2 && (scheme == 1 || scheme == 2)) burnAccepted(r35);
        else burnRejected(r35);
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
        bridge.burn(1, someRecipient());

        vm.prank(alice);
        assertTrue(token.transfer(bob, 1e8));
        assertEq(token.balanceOf(bob), 1e8);

        bridge.setPaused(false, signedSetPaused(false));
        assertFalse(bridge.paused());
        assertEq(bridge.adminNonce(), 2);
        bridge.mint(lock2, 1, alice, sigs); // signed while paused, still valid after
        vm.prank(alice);
        bridge.burn(1, someRecipient());
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
        // adminNonce moved: the contract's digest is now the nonce-1 one, over which the old
        // signature recovers to a non-guardian.
        expectNotGuardian(setPausedDigest(true, 1), sigs[0]);
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
        bridge.burn(1, someRecipient());

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
