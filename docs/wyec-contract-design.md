# wYEC on Ethereum: from the deployed WRY to a bridge token

Status: design note, 2026-10-05, prepared in `wt/wry` against `docs/plans/yellowback-upgrade-plan.md`
revision 2 (§4.3, §10, §11, O-4, O-9). Nothing here is committed to a component repo yet; the
`wyec/` repository (plan P5) will be created from it.

## 1. What is deployed today, and why it cannot be reused

`contracts/Wry.sol` in this repository is byte-for-byte the source Sourcify matches to
`0x1dff69d892d7a503088522b830eadcba9867f6bd` (exact creation and runtime match, verified 2024-08-08,
solc 0.6.12, no optimizer, not a proxy). It is OpenZeppelin 3.x `ERC20` plus a constructor:

```solidity
constructor(string name, string symbol, uint256 initialSupply, address owner)
    ERC20(name, symbol) { _mint(owner, initialSupply); _setupDecimals(8); }
```

| Property | Deployed WRY |
|---|---|
| Supply | 21,000,000.00000000, minted once in the constructor to `0xc41c…57d4` |
| Mint after deployment | none: no function reaches `_mint` |
| Burn | none: `_burn` is never exposed; transfers to `address(0)` revert |
| Admin, pause, upgrade | none: no owner, no roles, no proxy |
| Backing | an off-chain promise by whoever holds the undistributed balance |

The contract exposes exactly the eleven ERC-20 functions. There is no code path that can be
extended, so a mint-on-lock, burn-on-release bridge needs a **new contract**. WRY stays a legacy
custodial IOU with its own ticker; whether a one-way swap into wYEC is offered depends on the
custodian still holding the YEC, and is the Foundation's call, not this design's.

## 2. What the plan requires of the Ethereum side (§4.3, R1–R3)

1. `mint(lockId, amount, to, sigs[])`: guardian threshold, `lockId` an opaque `bytes32` the
   contract stores and never parses (R2), each lock mintable once.
2. `burn(amount, ycashRecipient)`: the holder's own act, unconditional, emitting the event the
   daemon turns into a Ycash intent. The recipient is opaque bytes on this side too.
3. Guardian set rotation and pause by the same threshold.
4. No Equihash, no SPV, no light client, nothing that reads Ycash state.
5. The guardians sign on both chains with the same secp256k1 key. Ethereum `ecrecover` is
   ECDSA/secp256k1 over a 32-byte digest, as Ycash's `CKey::Sign` is, so one key serves both
   chains; the Ethereum identity is `keccak256(uncompressed pubkey)[12:]`, which the daemon
   derives from the key registered on Ycash (`SET_JOIN`).

Nothing in the plan requires the token itself to carry any of this. That is the design lever.

## 3. OpenZeppelin extension survey (v5.7.0, master @ 40a51f7, 2026-10-01)

| Extension | Fit | Verdict |
|---|---|---|
| `draft-ERC20Bridgeable` (ERC-7802) | `crosschainMint(to, v)` / `crosschainBurn(from, v)` gated by one abstract `_checkTokenBridge(caller)`; emits standard `CrosschainMint`/`CrosschainBurn` events indexers already understand | **use**. Exactly "a bridge may mint and burn, nothing else may" with one hook to fill in |
| `ERC20Crosschain` + `BridgeFungible` (ERC-7786) | token is its own bridge over ERC-7786 gateways | reject: there is no ERC-7786 gateway to Ycash and never will be (R2); it drags in gateway routing we do not want |
| `ERC20Burnable` | permissionless `burn(v)` / `burnFrom` | reject as-is: a burn with no Ycash recipient is an unredeemable burn. The bridge contract provides `burn(amount, recipient)` and calls `crosschainBurn` |
| `ERC20Pausable` | pauses every transfer | reject on the token: pausing third parties' wYEC transfers is a trust ask the plan does not make. `Pausable` goes on the **bridge** (mint and burn only) |
| `ERC20Capped` | hard supply cap | optional: a cap equal to the YEC supply (21e6) is a free invariant; harmless |
| `ERC20Permit` | gasless approvals | optional, standard, orthogonal; include (every modern token does) |
| `ERC20Votes`, `ERC4626`, `ERC20FlashMint`, `ERC1363`, `ERC20Wrapper` | governance, vault shares, flash loans, callbacks, wrapping another ERC-20 | not applicable |
| `access/AccessControl` | role per address, one tx per actor | reject for the threshold: the plan wants `sigs[]` in one call. Keep for the single admin that points the token at its bridge, if any |
| `utils/cryptography/ECDSA`, `EIP712` | signature recovery and typed-data digests | **use** in the bridge for the guardian threshold |
| `utils/RateLimiter` (v5.7) | token-bucket per key | optional on the bridge's mint side as defence in depth; the consensus rate limit lives on Ycash releases (§3.5) |

## 4. Recommended shape: two contracts, policy outside the token

Mirror OpenZeppelin's own split (`ERC20Bridgeable` token, `BridgeERC7802` bridge):

```
WrappedYcash (the token)              WyecBridge (the policy)
ERC20 + ERC20Permit + ERC20Bridgeable  EIP712 + Pausable
decimals() = 8                        guardians[], threshold
_checkTokenBridge: caller == bridge   consumed[lockId]
                                      mint(lockId, amount, to, sigs[])  → token.crosschainMint
                                      burn(amount, bytes32 ycashRecipient) → token.crosschainBurn, emit BurnToYcash
                                      setGuardians(newSet, newThreshold, nonce, sigs[])
                                      setPaused(bool, nonce, sigs[])
```

**Why the split rather than one contract.** The token is the thing exchanges list and holders
trust; it should be ~30 lines of stock OpenZeppelin with no policy in it, so an audit of the
token is a reading, not a review. Everything that can be wrong (signature verification, replay,
set rotation, pause) is in the bridge, which the guardian set can retire by pointing the token at
a successor (`setBridge`, itself threshold-signed through the old bridge) without migrating
balances. That is the only "upgrade" path; no proxy anywhere (one admin key for a proxy is the
single point of compromise §11 refuses).

**Minimal delta from the standard.** The token overrides exactly two things: `decimals()` (8,
matching zatoshi and the old WRY, so amounts cross without scaling) and `_checkTokenBridge`
(equality against one storage slot). The bridge is net-new code, deliberately small, and the
only place the external audit (P5, critical path) has to concentrate.

### 4.1 Mint

```
mint(bytes32 lockId, uint256 amount, address to, bytes[] sigs)
  require !paused, !consumed[lockId]
  digest = EIP712(Mint(lockId, amount, to))          -- domain binds chainId + bridge address
  verify ≥ threshold distinct current-guardian signatures (signers strictly ascending → dedupe)
  consumed[lockId] = true
  token.crosschainMint(to, amount); emit Minted(lockId, to, amount)
```

- `lockId` is `bytes32` and opaque. The daemon defines it as `sha256(txid ‖ vout)` of the vault
  output (one vault output, one mint), but the contract never knows that (R2).
- No per-signer nonce: the lock id is the replay key. A signature for `(lockId, amount, to)` can
  be used once ever, by anyone who holds the signatures; whoever submits pays gas (the daemon, or
  the depositor). Amount and recipient are inside the signed struct, so a submitter cannot alter
  them.
- `to` is the `destination 32` the wallet wrote into the Ycash `OP_RETURN` at lock time. The
  daemon reads it there; the contract sees only what the guardians signed.

### 4.2 Burn

```
burn(uint256 amount, bytes32 ycashRecipient)
  require !paused
  token.crosschainBurn(msg.sender, amount)             -- bridge is the token's only burner
  emit BurnToYcash(burnNonce++, msg.sender, amount, ycashRecipient)
```

- Unconditional for the holder: the guardians cannot refuse an exit on Ethereum (they act, or
  are cancelled, on the Ycash release; and if they go silent the depositor branch opens, R1).
- `ycashRecipient` is 32 opaque bytes. The daemon maps it to a transparent Ycash address
  (20-byte hash, left-padded; the wallet composes it). The event's `(nonce, amount, recipient)`
  is what the daemon posts as the Ycash intent; `nonce` is the bridge's monotone counter so the
  Ycash-side equivocation guard (plan §3.6, S16) has a stable key.
- Because the bridge calls `crosschainBurn(msg.sender, …)`, the holder needs no allowance and
  no two-step. A `burnFrom` variant with allowance is a one-liner if a contract holder needs it.
- Only burns in **finalised** Ethereum blocks become intents (daemon policy, §11 row 3).

### 4.3 Guardian set and pause

- `guardians`: an address array plus `isGuardian` map; `threshold` ≤ length. Initialised in the
  constructor from the set registered on Ycash at the bridge-enable height (P8 "the contract
  deployed with the registered set").
- `setGuardians(address[] newSet, uint8 newThreshold, bytes[] sigs)` and
  `setPaused(bool, bytes[] sigs)`, each over an EIP-712 struct carrying a bridge-wide
  `adminNonce` that increments per admin act (rotation and pause are rare, so a single nonce
  suffices and keeps the audit surface tiny). Rotation needs `threshold` signatures of the
  **current** set, the same shape as Ycash's `SET_REMOVE` on the chain side.
- The plan's two signer shapes (§4.2, O-9) are both just `(guardians, threshold)`: 9/6 or 1/1.
  A challenger set on Ethereum is unnecessary: the only Ethereum-side act a challenger would stop
  is a bad mint, and a bad mint is bounded by the signatures required, not by a delay.
- Pause stops mint and burn, not transfers. A paused burn is a holder inconvenience, never a
  loss, since the YEC side cannot release without a burn anyway.

### 4.4 Supply invariant

`token.totalSupply() == Σ amount of consumed locks − Σ burned` holds by construction, and the
daemon checks `totalSupply ≤ YEC in live WYEC vaults` every block as a liveness alarm. An
`ERC20Capped` at 21,000,000 YEC is a free upper bound and costs one import.

## 5. What is deliberately not in the contract

- Any verification of Ycash data (block headers, Equihash, payloads). R2.
- Any release logic. Release, delay, cancel, rate limit and slashing are Ycash consensus (§3).
- A proxy. Successor bridges, not upgrades.
- Transfer pausing or blacklisting.
- A mint-side rate limit in v1 (an `RateLimiter` bucket is a ten-line addition if the audit
  wants defence in depth; the consensus cap is on the Ycash side).

## 6. Open points for the plan (to raise with the owner / Foundation)

| # | Question | Recommendation |
|---|---|---|
| E-1 | Ticker and name of the new token | `wYEC` / "Wrapped Ycash"; WRY keeps its contract and ticker as a legacy asset |
| E-2 | Disposition of WRY | leave alone and name it in the plan; a swap only with the custodian's cooperation and reserve audit |
| E-3 | Successor-bridge path (`setBridge` threshold-signed) vs immutable bridge address | threshold-signed successor; immutable would force a token migration on any bridge defect |
| E-4 | Pause scope | mint+burn only (bridge), never transfers |
| E-5 | `lockId` derivation | daemon convention `sha256(txid‖vout)`; opaque on both sides |
| E-6 | Mint-side `RateLimiter` | defer to the audit |
| E-7 | `ERC20Capped` at 21e6 | include |

## 7. Files in this worktree

- `contracts/Wry.sol`: the 2021 contract, untouched (the deployed reference).
- `contracts/v2/WrappedYcash.sol`: the token draft (§4).
- `contracts/v2/WyecBridge.sol`: the bridge draft (§4.1–4.3).
- `contracts/v2/README.md`: how to compile the drafts with `solc` from npm, pending a Foundry
  setup in the real `wyec/` repo.

## 8. Deployment order (found by the compile check)

The token's constructor takes the bridge address and the bridge's constructor takes the token
address. Deploy the bridge first with the token address **predicted** from the deployer's next
nonce (`CREATE` address = `keccak256(rlp(deployer, nonce))`), then deploy the token in the very
next transaction from the same deployer. A Foundry script asserts the prediction before
broadcasting. No post-deploy setter is needed, so neither contract has an admin that could point
it somewhere else.

Compile check, 2026-10-05: both drafts build with solc 0.8.37 and OpenZeppelin 5.6.1 (optimizer
on, 200 runs); deployed sizes 4,683 bytes (token) and 5,361 bytes (bridge). `contracts/v2/compile.js`.
