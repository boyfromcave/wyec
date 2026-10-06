// SPDX-License-Identifier: MIT
// Copyright (c) 2026 The Ycash developers
pragma solidity ^0.8.24;

import {IERC7802} from "@openzeppelin/contracts/interfaces/draft-IERC7802.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface IWrappedYcash is IERC7802 {
    function setBridge(address newBridge) external;
}

/**
 * The wYEC bridge: all policy for minting and burning Wrapped Ycash (plan §4.3).
 *
 * Mint:  guardian threshold over an EIP-712 Mint(lockId, amount, to); each lockId once ever.
 *        lockId is opaque bytes32 (the daemon's convention is sha256(txid || vout) of the Ycash
 *        vault output); the contract stores it and never interprets it (R2).
 * Burn:  the holder's own, unconditional act. Emits BurnToYcash(nonce, from, amount, recipient)
 *        which the guardian daemon turns into a Ycash intent (recipient is opaque bytes32).
 * Admin: guardian rotation, pause, and handing the token to a successor bridge, each under the
 *        same threshold over an EIP-712 struct carrying `adminNonce`.
 *
 * Signatures are secp256k1 ECDSA, so the guardians sign here with the key they registered on
 * Ycash (SET_JOIN); their Ethereum address is derived from that public key off-chain.
 * There is no release logic here: release, delay, cancel, rate limit and slashing are Ycash
 * consensus rules (plan §3).
 */
contract WyecBridge is EIP712, Pausable {
    bytes32 private constant MINT_TYPEHASH =
        keccak256("Mint(bytes32 lockId,uint256 amount,address to)");
    bytes32 private constant SET_GUARDIANS_TYPEHASH =
        keccak256("SetGuardians(address[] guardians,uint8 threshold,uint256 adminNonce)");
    bytes32 private constant SET_PAUSED_TYPEHASH =
        keccak256("SetPaused(bool paused,uint256 adminNonce)");
    bytes32 private constant SET_BRIDGE_TYPEHASH =
        keccak256("SetBridge(address newBridge,uint256 adminNonce)");

    IWrappedYcash public immutable token;

    address[] public guardians;
    mapping(address => bool) public isGuardian;
    uint8 public threshold;

    mapping(bytes32 lockId => bool) public consumed;
    uint256 public burnNonce;
    uint256 public adminNonce;

    event Minted(bytes32 indexed lockId, address indexed to, uint256 amount);
    event BurnToYcash(uint256 indexed nonce, address indexed from, uint256 amount, bytes32 ycashRecipient);
    event GuardiansChanged(address[] guardians, uint8 threshold);

    error BadGuardianSet();
    error LockConsumed(bytes32 lockId);
    error SignersNotAscending();
    error NotGuardian(address signer);
    error Threshold(uint256 got, uint256 need);

    constructor(IWrappedYcash token_, address[] memory guardians_, uint8 threshold_)
        EIP712("WyecBridge", "1")
    {
        token = token_;
        _setGuardians(guardians_, threshold_);
    }

    // ---------------------------------------------------------------- mint / burn

    function mint(bytes32 lockId, uint256 amount, address to, bytes[] calldata sigs)
        external
        whenNotPaused
    {
        if (consumed[lockId]) revert LockConsumed(lockId);
        _checkThreshold(_hashTypedDataV4(keccak256(abi.encode(MINT_TYPEHASH, lockId, amount, to))), sigs);
        consumed[lockId] = true;
        token.crosschainMint(to, amount);
        emit Minted(lockId, to, amount);
    }

    function burn(uint256 amount, bytes32 ycashRecipient) external whenNotPaused {
        token.crosschainBurn(msg.sender, amount);
        emit BurnToYcash(burnNonce++, msg.sender, amount, ycashRecipient);
    }

    // ---------------------------------------------------------------- admin (threshold-signed)

    function setGuardians(address[] calldata guardians_, uint8 threshold_, bytes[] calldata sigs) external {
        bytes32 structHash = keccak256(
            abi.encode(SET_GUARDIANS_TYPEHASH, keccak256(abi.encodePacked(guardians_)), threshold_, adminNonce++)
        );
        _checkThreshold(_hashTypedDataV4(structHash), sigs);
        _setGuardians(guardians_, threshold_);
    }

    function setPaused(bool paused_, bytes[] calldata sigs) external {
        _checkThreshold(_hashTypedDataV4(keccak256(abi.encode(SET_PAUSED_TYPEHASH, paused_, adminNonce++))), sigs);
        if (paused_) _pause(); else _unpause();
    }

    /// Retires this bridge in favour of a successor. After this call nothing here can mint or burn.
    function setBridge(address newBridge, bytes[] calldata sigs) external {
        _checkThreshold(_hashTypedDataV4(keccak256(abi.encode(SET_BRIDGE_TYPEHASH, newBridge, adminNonce++))), sigs);
        token.setBridge(newBridge);
    }

    function guardianCount() external view returns (uint256) {
        return guardians.length;
    }

    // ---------------------------------------------------------------- internals

    function _setGuardians(address[] memory guardians_, uint8 threshold_) internal {
        if (threshold_ == 0 || threshold_ > guardians_.length) revert BadGuardianSet();
        for (uint256 i = 0; i < guardians.length; i++) isGuardian[guardians[i]] = false;
        for (uint256 i = 0; i < guardians_.length; i++) {
            address g = guardians_[i];
            if (g == address(0) || isGuardian[g]) revert BadGuardianSet();
            isGuardian[g] = true;
        }
        guardians = guardians_;
        threshold = threshold_;
        emit GuardiansChanged(guardians_, threshold_);
    }

    /// `sigs` must be ordered by strictly ascending recovered address: that makes distinctness a
    /// single comparison and rejects a duplicated signature without any extra storage.
    function _checkThreshold(bytes32 digest, bytes[] calldata sigs) internal view {
        if (sigs.length < threshold) revert Threshold(sigs.length, threshold);
        address last = address(0);
        for (uint256 i = 0; i < sigs.length; i++) {
            address signer = ECDSA.recover(digest, sigs[i]);
            if (signer <= last) revert SignersNotAscending();
            if (!isGuardian[signer]) revert NotGuardian(signer);
            last = signer;
        }
    }
}
