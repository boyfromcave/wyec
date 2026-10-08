// SPDX-License-Identifier: MIT
// Copyright (c) 2026 The Ycash developers
pragma solidity ^0.8.24;

import {IERC7802} from "@openzeppelin/contracts/interfaces/draft-IERC7802.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice The token interface the bridge drives: ERC-7802 mint/burn plus the successor hand-off.
interface IWrappedYcash is IERC7802 {
    /// @notice Hands the token's mint/burn right to `newBridge` (callable by the current bridge only).
    function setBridge(address newBridge) external;
}

/**
 * @title WyecBridge
 * @notice The wYEC bridge: all policy for minting and burning Wrapped Ycash (upgrade plan §4.3,
 *         docs/wyec-contract-design.md §4).
 *
 * Mint, two paths, one signed message. Both verify EIP-712 `Mint(bytes32 lockId,uint256 amount,address to)`;
 * each lockId mints at most once ever.
 *   - Threshold (fast) path, `mint`: `threshold` distinct current-guardian signatures, immediate.
 *   - Optimistic path (design §4.5): `proposeMint` with ONE current guardian's signature opens a
 *     proposal; during `challengeWindow` seconds any one current guardian's EIP-712
 *     `Challenge(bytes32 lockId,uint256 proposalId)` signature deletes it (`challengeMint`); after
 *     the window anyone may `executeMint`. Slashing of a fraudulent proposer happens on Ycash
 *     (its bond); this contract only stops the mint and leaves the evidence in its events.
 *   An optional fixed-window rate limit (`mintCap` per `capWindow` seconds) bounds both paths.
 *   lockId is opaque bytes32 (the daemon's convention is sha256(txid || vout) of the Ycash vault
 *   output); the contract stores it and never interprets it (R2).
 * Burn:  the holder's own, unconditional act. Emits BurnToYcash(nonce, from, amount, recipient)
 *        which the guardian daemon turns into a Ycash intent (recipient: see `burn`).
 * Admin: guardian rotation, pause, mint rate limit and handing the token to a successor bridge,
 *        each under the threshold over an EIP-712 struct carrying the shared `adminNonce`.
 *
 * Signatures are secp256k1 ECDSA (low-S, OpenZeppelin ECDSA), so the guardians sign here with the
 * key they registered on Ycash (SET_JOIN); their Ethereum address is derived from that public key
 * off-chain. Every signature may be submitted by anyone, so guardian keys need hold no ETH.
 *
 * Security note: the optimistic path only adds a window if no single key can bypass it, i.e. if
 * `threshold >= 2`. With `threshold == 1` one key mints immediately through `mint` and can also
 * lift the rate limit; such a deployment is for development only (design §4.5).
 *
 * There is no release logic here: release, delay, cancel, rate limit and slashing of the Ycash
 * side are Ycash consensus rules (plan §3).
 */
contract WyecBridge is EIP712, Pausable {
    bytes32 private constant MINT_TYPEHASH = keccak256("Mint(bytes32 lockId,uint256 amount,address to)");
    bytes32 private constant CHALLENGE_TYPEHASH = keccak256("Challenge(bytes32 lockId,uint256 proposalId)");
    bytes32 private constant SET_GUARDIANS_TYPEHASH =
        keccak256("SetGuardians(address[] guardians,uint8 threshold,uint256 adminNonce)");
    bytes32 private constant SET_PAUSED_TYPEHASH = keccak256("SetPaused(bool paused,uint256 adminNonce)");
    bytes32 private constant SET_BRIDGE_TYPEHASH =
        keccak256("SetBridge(address newBridge,uint256 adminNonce)");
    bytes32 private constant SET_MINT_LIMIT_TYPEHASH =
        keccak256("SetMintLimit(uint256 mintCap,uint256 capWindow,uint256 adminNonce)");

    /// @notice A pending optimistic mint (three storage slots).
    /// @param to        recipient of the mint
    /// @param eta       earliest `block.timestamp` at which `executeMint` succeeds
    /// @param proposer  the guardian whose `Mint` signature opened the proposal
    /// @param id        unique, non-zero proposal id (`proposalCount` at proposal time); 0 = none
    /// @param amount    wYEC base units (8 decimals)
    struct Proposal {
        address to;
        uint64 eta;
        address proposer;
        uint96 id;
        uint256 amount;
    }

    /// @notice What `executeMint(lockId)` would find right now (pause and rate limit aside).
    enum ProposalStatus {
        None, // no proposal for this lockId
        Pending, // inside the challenge window
        Ready, // window passed, proposer still a guardian: executable
        Void // proposer no longer a guardian: not executable, may be re-proposed
    }

    /// @notice The token this bridge mints and burns.
    IWrappedYcash public immutable token;

    /// @notice Seconds between `proposeMint` and the earliest `executeMint` (> 0).
    uint64 public immutable challengeWindow;

    /// @notice The current guardian set, in the order it was set.
    address[] public guardians;
    /// @notice Membership of the current guardian set.
    mapping(address => bool) public isGuardian;
    /// @notice Signatures needed by `mint` and by every admin act.
    uint8 public threshold;

    /// @notice lockIds that have minted (by either path). Never cleared.
    mapping(bytes32 lockId => bool) public consumed;
    /// @notice Next `BurnToYcash` nonce.
    uint256 public burnNonce;
    /// @notice Nonce bound into every admin act's signed struct; shared by all admin acts.
    uint256 public adminNonce;

    /// @notice Pending optimistic mints by lockId (at most one per lockId).
    mapping(bytes32 lockId => Proposal) public proposals;
    /// @notice Number of proposals ever opened; the last proposal id issued.
    uint96 public proposalCount;

    /// @notice Most wYEC base units both mint paths together may mint per window; 0 = no limit.
    uint256 public mintCap;
    /// @notice Rate-limit window length in seconds; windows are `block.timestamp / capWindow`.
    uint256 public capWindow;
    /// @notice Index of the window `mintedInWindow` counts.
    uint256 public mintWindow;
    /// @notice wYEC base units minted in window `mintWindow` (counted only while `mintCap != 0`).
    uint256 public mintedInWindow;

    /// @notice A lock minted, by either path.
    event Minted(bytes32 indexed lockId, address indexed to, uint256 amount);
    /// @notice A holder burned `amount` for release to `ycashRecipient` on Ycash.
    event BurnToYcash(uint256 indexed nonce, address indexed from, uint256 amount, bytes32 ycashRecipient);
    /// @notice The guardian set or threshold changed.
    event GuardiansChanged(address[] guardians, uint8 threshold);
    /// @notice The mint rate limit changed (also emitted by the constructor).
    event MintLimitChanged(uint256 mintCap, uint256 capWindow);
    /// @notice `proposer` signed `Mint(lockId, amount, to)`; executable from `eta` unless challenged.
    event MintProposed(
        bytes32 indexed lockId,
        uint256 indexed proposalId,
        address indexed proposer,
        address to,
        uint256 amount,
        uint64 eta
    );
    /// @notice Guardian `challenger` signed `Challenge(lockId, proposalId)`; the proposal is deleted.
    event MintChallenged(bytes32 indexed lockId, uint256 indexed proposalId, address indexed challenger);

    /// @notice Empty set, zero/duplicate member, or threshold 0 or above the set size.
    error BadGuardianSet();
    /// @notice The lockId has already minted.
    error LockConsumed(bytes32 lockId);
    /// @notice Threshold signatures must recover to strictly ascending addresses.
    error SignersNotAscending();
    /// @notice A signature recovered to an address outside the current guardian set.
    error NotGuardian(address signer);
    /// @notice Fewer signatures than the threshold.
    error Threshold(uint256 got, uint256 need);
    /// @notice The constructor's `challengeWindow` is zero.
    error ZeroChallengeWindow();
    /// @notice `mintCap != 0` with `capWindow == 0`.
    error BadMintLimit();
    /// @notice `proposeMint` with `amount == 0`.
    error ZeroAmount();
    /// @notice `proposeMint` with `to == address(0)`.
    error ZeroRecipient();
    /// @notice A live (non-void) proposal already exists for the lockId.
    error ProposalPending(bytes32 lockId, uint256 proposalId);
    /// @notice No proposal for the lockId (`executeMint`), or not the one named (`challengeMint`).
    error NoProposal(bytes32 lockId, uint256 proposalId);
    /// @notice `executeMint` before the proposal's `eta`.
    error ChallengeWindowOpen(uint64 eta);
    /// @notice The proposal's proposer has been rotated out of the guardian set.
    error ProposerNotGuardian(address proposer);
    /// @notice The mint would exceed `mintCap` in the current window; `available` remains.
    error MintRateLimited(uint256 amount, uint256 available);

    /// @param token_           the token, deployed next at its predicted address (design §8)
    /// @param guardians_       initial guardian set (the set registered on Ycash)
    /// @param threshold_       signatures needed by `mint` and the admin acts
    /// @param challengeWindow_ optimistic-mint challenge window in seconds, > 0
    /// @param mintCap_         initial rate limit per window in base units; 0 = no limit
    /// @param capWindow_       initial window length in seconds; > 0 when `mintCap_ != 0`
    constructor(
        IWrappedYcash token_,
        address[] memory guardians_,
        uint8 threshold_,
        uint64 challengeWindow_,
        uint256 mintCap_,
        uint256 capWindow_
    ) EIP712("WyecBridge", "1") {
        if (challengeWindow_ == 0) revert ZeroChallengeWindow();
        token = token_;
        challengeWindow = challengeWindow_;
        _setGuardians(guardians_, threshold_);
        _setMintLimit(mintCap_, capWindow_);
    }

    // ---------------------------------------------------------------- mint: threshold path

    /// @notice Mints `amount` to `to` for `lockId` on `threshold` guardian signatures, immediately.
    ///         Clears any pending optimistic proposal for the same lockId.
    /// @param sigs signatures over the EIP-712 `Mint(lockId, amount, to)` digest, ordered by strictly
    ///        ascending recovered address
    function mint(bytes32 lockId, uint256 amount, address to, bytes[] calldata sigs) external whenNotPaused {
        if (consumed[lockId]) revert LockConsumed(lockId);
        _checkThreshold(mintDigest(lockId, amount, to), sigs);
        if (proposals[lockId].id != 0) delete proposals[lockId];
        _mint(lockId, amount, to);
    }

    // ---------------------------------------------------------------- mint: optimistic path

    /// @notice Opens an optimistic mint on ONE current guardian's signature. Callable by anyone.
    /// @dev    A proposal whose proposer has left the guardian set is void and is replaced.
    /// @param sig the proposer's signature over the same EIP-712 `Mint(lockId, amount, to)` digest
    ///        the threshold path verifies
    /// @return proposalId the new proposal's id
    function proposeMint(bytes32 lockId, uint256 amount, address to, bytes calldata sig)
        external
        whenNotPaused
        returns (uint256 proposalId)
    {
        if (consumed[lockId]) revert LockConsumed(lockId);
        if (to == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();
        Proposal storage p = proposals[lockId];
        if (p.id != 0 && isGuardian[p.proposer]) revert ProposalPending(lockId, p.id);
        address signer = ECDSA.recover(mintDigest(lockId, amount, to), sig);
        if (!isGuardian[signer]) revert NotGuardian(signer);

        uint96 id = ++proposalCount;
        uint64 eta = uint64(block.timestamp) + challengeWindow;
        proposals[lockId] = Proposal({to: to, eta: eta, proposer: signer, id: id, amount: amount});
        emit MintProposed(lockId, id, signer, to, amount, eta);
        return id;
    }

    /// @notice Deletes proposal `proposalId` for `lockId` on ANY one current guardian's signature.
    ///         Callable by anyone, also while paused. The lockId is not consumed: a correct mint
    ///         can be proposed again. A guardian may challenge its own proposal.
    /// @param sig a guardian's signature over EIP-712 `Challenge(lockId, proposalId)`; binding the
    ///        proposal id means a challenge cannot be replayed against a later re-proposal
    function challengeMint(bytes32 lockId, uint256 proposalId, bytes calldata sig) external {
        uint96 id = proposals[lockId].id;
        if (id == 0 || id != proposalId) revert NoProposal(lockId, proposalId);
        address signer = ECDSA.recover(challengeDigest(lockId, proposalId), sig);
        if (!isGuardian[signer]) revert NotGuardian(signer);
        delete proposals[lockId];
        emit MintChallenged(lockId, proposalId, signer);
    }

    /// @notice Executes the proposal for `lockId` once its window has passed. Callable by anyone.
    /// @dev    Reverts `ProposerNotGuardian` if the proposer has since been rotated out: such a
    ///         proposal is void (re-propose, challenge, or mint by threshold). Subject to the rate
    ///         limit; a proposal over the limit stays pending and can be executed in a later window.
    function executeMint(bytes32 lockId) external whenNotPaused {
        Proposal memory p = proposals[lockId];
        if (p.id == 0) revert NoProposal(lockId, 0);
        // A window of minutes to hours; validator timestamp drift is seconds.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.eta) revert ChallengeWindowOpen(p.eta);
        if (!isGuardian[p.proposer]) revert ProposerNotGuardian(p.proposer);
        // Invariant: a lockId with a proposal is never consumed (propose checks; mint clears).
        delete proposals[lockId];
        _mint(lockId, p.amount, p.to);
    }

    // ---------------------------------------------------------------- burn

    /// @notice Burns `amount` of the caller's wYEC for release on Ycash. Unconditional (no
    ///         allowance, no guardian); stopped only by pause. Emits `BurnToYcash` with the next nonce.
    /// @param ycashRecipient opaque to this contract (R2). Hawkeye's encoding (Hawkeye plan §4.2):
    ///        byte 0 version `0x01`; byte 1 kind `0x00` P2PKH or `0x01` P2SH; bytes 2..11 zero;
    ///        bytes 12..31 the 20-byte hash160. The release pays `OP_DUP OP_HASH160 <20>
    ///        OP_EQUALVERIFY OP_CHECKSIG` (P2PKH) or `OP_HASH160 <20> OP_EQUAL` (P2SH). Any other
    ///        value cannot be paid out; shielded recipients are out of scope.
    function burn(uint256 amount, bytes32 ycashRecipient) external whenNotPaused {
        token.crosschainBurn(msg.sender, amount);
        emit BurnToYcash(burnNonce++, msg.sender, amount, ycashRecipient);
    }

    // ---------------------------------------------------------------- admin (threshold-signed)

    /// @notice Replaces the guardian set and threshold. Works while paused.
    /// @param sigs threshold of the CURRENT set over `SetGuardians(guardians, threshold, adminNonce)`
    function setGuardians(address[] calldata guardians_, uint8 threshold_, bytes[] calldata sigs) external {
        bytes32 structHash = keccak256(
            abi.encode(
                SET_GUARDIANS_TYPEHASH, keccak256(abi.encodePacked(guardians_)), threshold_, adminNonce++
            )
        );
        _checkThreshold(_hashTypedDataV4(structHash), sigs);
        _setGuardians(guardians_, threshold_);
    }

    /// @notice Pauses or unpauses mint (both paths) and burn; never transfers. Setting the current
    ///         state reverts.
    /// @param sigs threshold over `SetPaused(paused, adminNonce)`
    function setPaused(bool paused_, bytes[] calldata sigs) external {
        _checkThreshold(
            _hashTypedDataV4(keccak256(abi.encode(SET_PAUSED_TYPEHASH, paused_, adminNonce++))), sigs
        );
        if (paused_) _pause();
        else _unpause();
    }

    /// @notice Sets the mint rate limit for both paths. Resets the current window's running total.
    /// @param sigs threshold over `SetMintLimit(mintCap, capWindow, adminNonce)`
    function setMintLimit(uint256 mintCap_, uint256 capWindow_, bytes[] calldata sigs) external {
        _checkThreshold(
            _hashTypedDataV4(
                keccak256(abi.encode(SET_MINT_LIMIT_TYPEHASH, mintCap_, capWindow_, adminNonce++))
            ),
            sigs
        );
        _setMintLimit(mintCap_, capWindow_);
    }

    /// @notice Retires this bridge in favour of a successor. After this call nothing here can mint
    ///         or burn.
    /// @param sigs threshold over `SetBridge(newBridge, adminNonce)`
    function setBridge(address newBridge, bytes[] calldata sigs) external {
        _checkThreshold(
            _hashTypedDataV4(keccak256(abi.encode(SET_BRIDGE_TYPEHASH, newBridge, adminNonce++))), sigs
        );
        token.setBridge(newBridge);
    }

    // ---------------------------------------------------------------- views

    /// @notice Size of the current guardian set.
    function guardianCount() external view returns (uint256) {
        return guardians.length;
    }

    /// @notice The EIP-712 digest a guardian signs for a mint (either path).
    function mintDigest(bytes32 lockId, uint256 amount, address to) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(MINT_TYPEHASH, lockId, amount, to)));
    }

    /// @notice The EIP-712 digest a guardian signs to challenge proposal `proposalId`.
    function challengeDigest(bytes32 lockId, uint256 proposalId) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CHALLENGE_TYPEHASH, lockId, proposalId)));
    }

    /// @notice The proposal for `lockId` (all-zero if none).
    function getProposal(bytes32 lockId) external view returns (Proposal memory) {
        return proposals[lockId];
    }

    /// @notice The status of the proposal for `lockId`; ignores pause and the rate limit.
    function proposalStatus(bytes32 lockId) external view returns (ProposalStatus) {
        Proposal storage p = proposals[lockId];
        if (p.id == 0) return ProposalStatus.None;
        if (!isGuardian[p.proposer]) return ProposalStatus.Void;
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp < p.eta ? ProposalStatus.Pending : ProposalStatus.Ready;
    }

    /// @notice Base units mintable now under the rate limit (`type(uint256).max` if no limit).
    function mintAvailable() external view returns (uint256) {
        uint256 cap = mintCap;
        if (cap == 0) return type(uint256).max;
        // forge-lint: disable-next-line(block-timestamp)
        return cap - (block.timestamp / capWindow == mintWindow ? mintedInWindow : 0);
    }

    // ---------------------------------------------------------------- internals

    /// Consumes `lockId`, applies the rate limit and mints. The caller has checked authorisation.
    function _mint(bytes32 lockId, uint256 amount, address to) internal {
        consumed[lockId] = true;
        uint256 cap = mintCap;
        if (cap != 0) {
            // Invariant: mintedInWindow <= mintCap (only raised within the cap; reset on a change).
            uint256 w = block.timestamp / capWindow;
            uint256 used = w == mintWindow ? mintedInWindow : 0;
            if (amount > cap - used) revert MintRateLimited(amount, cap - used);
            mintWindow = w;
            mintedInWindow = used + amount;
        }
        token.crosschainMint(to, amount);
        emit Minted(lockId, to, amount);
    }

    function _setGuardians(address[] memory guardians_, uint8 threshold_) internal {
        if (threshold_ == 0 || threshold_ > guardians_.length) revert BadGuardianSet();
        for (uint256 i = 0; i < guardians.length; i++) {
            isGuardian[guardians[i]] = false;
        }
        for (uint256 i = 0; i < guardians_.length; i++) {
            address g = guardians_[i];
            if (g == address(0) || isGuardian[g]) revert BadGuardianSet();
            isGuardian[g] = true;
        }
        guardians = guardians_;
        threshold = threshold_;
        emit GuardiansChanged(guardians_, threshold_);
    }

    /// The running total restarts: a quorum able to set the cap could raise it anyway.
    function _setMintLimit(uint256 mintCap_, uint256 capWindow_) internal {
        if (mintCap_ != 0 && capWindow_ == 0) revert BadMintLimit();
        mintCap = mintCap_;
        capWindow = capWindow_;
        mintWindow = mintCap_ == 0 ? 0 : block.timestamp / capWindow_;
        mintedInWindow = 0;
        emit MintLimitChanged(mintCap_, capWindow_);
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
