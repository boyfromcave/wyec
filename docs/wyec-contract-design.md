# wYEC on Ethereum: from the deployed WRY to a bridge token

Status: design note, 2026-10-05, prepared against the workspace `docs/plans/yellowback-upgrade-plan.md`
revision 2 (§4.3, §10, §11, O-4, O-9). This repository is the plan's `wyec/` component (P5); the
drafts are not yet reviewed or audited.

Revision 2026-10-08: the optimistic mint and the mint rate limit (§4.5; Hawkeye plan
`docs/hawkeye-bridge-plan.md` CR-W1), the recipient encoding in the contract's NatSpec (§4.2,
CR-W3), and a Foundry project replacing the npm compile check (§7, §8, CR-W2).

## 1. What is deployed today, and why it cannot be reused

`contracts/Wry.sol` in https://github.com/boyfromcave/wry is byte-for-byte the source Sourcify matches to
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
5. (Added with the Foundation's attestation model, Hawkeye plan §0 item 4.) One attestation, a
   challenge window and slashing: the same shape as the Ycash release side, so a single
   guardian's signature must not mint immediately. §4.5.
6. The guardians sign on both chains with the same secp256k1 key. Ethereum `ecrecover` is
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
decimals() = 8                        guardians[], threshold, challengeWindow (immutable)
_checkTokenBridge: caller == bridge   consumed[lockId], proposals[lockId], mintCap / capWindow
                                      mint(lockId, amount, to, sigs[])        → token.crosschainMint
                                      proposeMint(lockId, amount, to, sig)    one guardian (§4.5)
                                      challengeMint(lockId, proposalId, sig)  any one guardian
                                      executeMint(lockId)                     anyone, after the window
                                      burn(amount, bytes32 ycashRecipient) → token.crosschainBurn, emit BurnToYcash
                                      setGuardians(newSet, newThreshold, sigs[])
                                      setPaused(bool, sigs[])
                                      setMintLimit(mintCap, capWindow, sigs[])
                                      setBridge(successor, sigs[])
```

Every admin act signs an EIP-712 struct carrying the shared `adminNonce`.

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
- The rate limit (§4.5.4) applies, and a pending optimistic proposal for the same `lockId` is
  deleted: a quorum overrides one guardian's proposal. Otherwise unchanged by §4.5.

### 4.2 Burn

```
burn(uint256 amount, bytes32 ycashRecipient)
  require !paused
  token.crosschainBurn(msg.sender, amount)             -- bridge is the token's only burner
  emit BurnToYcash(burnNonce++, msg.sender, amount, ycashRecipient)
```

- Unconditional for the holder: the guardians cannot refuse an exit on Ethereum (they act, or
  are cancelled, on the Ycash release; and if they go silent the depositor branch opens, R1).
- `ycashRecipient` is 32 opaque bytes to the contract (R2). Its encoding is the daemon's (Hawkeye
  plan §4.2), restated in `burn`'s NatSpec (CR-W3): byte 0 version `0x01`; byte 1 kind `0x00`
  P2PKH or `0x01` P2SH; bytes 2..11 zero; bytes 12..31 the hash160. The release pays
  `OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG` or `OP_HASH160 <20> OP_EQUAL`; any other
  value cannot be paid, and shielded recipients are out of scope (the user shields after release). The event's `(nonce, amount, recipient)`
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
  On this contract 1/1 lets one key use the immediate `mint`, so it is a development setting; the
  Foundation's one-attestation model is the optimistic path over a set with `threshold >= 2` (§4.5.2).
  A separate challenger set on Ethereum is unnecessary: the guardians themselves challenge
  optimistic proposals (§4.5), exactly as the members of the one Ycash signer set cancel releases.
- `setMintLimit(mintCap, capWindow, sigs)` is the fourth admin act (§4.5.4).
- Pause stops mint and burn, not transfers. A paused burn is a holder inconvenience, never a
  loss, since the YEC side cannot release without a burn anyway.

### 4.4 Supply invariant

`token.totalSupply() == Σ amount of consumed locks − Σ burned` holds by construction, and the
daemon checks `totalSupply ≤ YEC in live WYEC vaults` every block as a liveness alarm. An
`ERC20Capped` at 21,000,000 YEC is a free upper bound and costs one import.

### 4.5 Optimistic mint (CR-W1)

**Why.** §4.1's mint is immediate under `threshold` signatures. The Foundation's attestation
model is *one attestation, a challenge window, slashing* (Hawkeye plan §0 items 3-4): on Ycash
that is one signer set with `unlockThreshold = 1`, `cancelThreshold = 1` and the vault's `delay`
as the window. Run on Ethereum with `threshold = 1`, one stolen key would mint up to the 21M cap
at once, with nothing for the other guardians to stop. The optimistic path gives the mint side
the same shape as the release side: one guardian proposes, a window passes during which any one
guardian can veto, then anyone executes. Slashing is not here: the fraudulent proposer's
signature over `Mint(lockId, amount, to)` is the evidence, and its bond is burned on Ycash
(`SET_REMOVE burn=1`); the contract only has to stop the mint and leave the evidence in events.

#### 4.5.1 Flow

```
proposeMint(bytes32 lockId, uint256 amount, address to, bytes sig) → proposalId     anyone submits
  require !paused, !consumed[lockId], to != 0, amount != 0
  require no live proposal for lockId (a proposal whose proposer left the set is void, replaced)
  signer = recover(EIP712(Mint(lockId, amount, to)), sig); require isGuardian[signer]
  proposals[lockId] = {to, eta = now + challengeWindow, proposer = signer, id = ++proposalCount, amount}
  emit MintProposed(lockId, id, proposer, to, amount, eta)

challengeMint(bytes32 lockId, uint256 proposalId, bytes sig)                         anyone submits
  require proposals[lockId].id == proposalId != 0                (works while paused)
  signer = recover(EIP712(Challenge(lockId, proposalId)), sig); require isGuardian[signer]
  delete proposals[lockId]                                       (lockId NOT consumed)
  emit MintChallenged(lockId, proposalId, signer)

executeMint(bytes32 lockId)                                                          anyone
  require !paused, a proposal exists, now >= eta, isGuardian[proposer]
  delete proposal; consumed[lockId] = true; rate limit; token.crosschainMint(to, amount)
  emit Minted(lockId, to, amount)                                (the same event as §4.1)
```

- **One message per lock.** The proposal's signature is over the same EIP-712 `Mint` digest the
  threshold path verifies, so an attestor signs one message per lock in either mode, and a
  proposer's signature also counts towards a threshold `mint` of the same lock.
- **Everything is a signature**, submittable by anyone: guardian keys need hold no ETH, and the
  key that signs on Ethereum is the key registered on Ycash (§2 item 6).
- **Proposal ids** are unique and increasing (`proposalCount`, `uint96`, packed with the
  proposer). A challenge names the id, so a challenge signed against one proposal can never
  delete a later re-proposal of the same lock (a correct mint is not blockable by replaying an
  old veto). A challenge also bars the challenged proposer from that lockId (`vetoed`), since its
  Mint signature is public after the first proposal and could otherwise be replayed by anyone
  after every challenge. A guardian may challenge its own proposal (to withdraw a mistake), and is
  then barred from re-proposing that lock itself.
- **Rotation.** A proposal is valid only while its proposer is a guardian; this is checked at
  execute. A proposer rotated out (for instance after a slash on Ycash) leaves a *void* proposal:
  `executeMint` reverts `ProposerNotGuardian`, and any current guardian's `proposeMint` replaces
  it with a fresh window (or it is challenged, or the lock is minted by threshold). If the
  proposer is later re-added, the proposal is live again. Challengers are likewise checked
  against the current set.
- **Pause** stops `proposeMint` and `executeMint`, never `challengeMint`: a pause is the moment
  guardians are clearing bad proposals. Windows keep running during a pause.
- **Threshold path interplay.** `mint` deletes a pending proposal for its `lockId`; a quorum
  can thus override a wrong proposal with the right `(amount, to)` without waiting.
- **Views.** `getProposal(lockId)`, `proposalStatus(lockId)` (`None`, `Pending`, `Ready`,
  `Void`; ignores pause and the rate limit), `mintDigest`, `challengeDigest`, `mintAvailable()`.

#### 4.5.2 Threats it addresses

| Threat | Without §4.5 | With §4.5 |
|---|---|---|
| One guardian key stolen or rogue (the Foundation's k = 1 model) | at `threshold = 1`: mints up to the cap immediately | proposes only; any one honest guardian challenges within `challengeWindow`; the signature is slashing evidence on Ycash |
| Fraudulent proposal: no lock behind `lockId`, wrong amount or recipient | n/a | challenged; the lock (if real) is re-proposed correctly or minted by threshold |
| Proposal squatting: a bad proposal placed first on a real `lockId` | n/a | blocks that lock only until challenged (one transaction); threshold `mint` overrides at once |
| Replaying an old challenge to block a correct re-proposal | n/a | `proposalId` binding |
| Replaying a challenged proposer's public Mint signature after every challenge (watchers would have to win every window until the guardian is rotated out) | n/a | `vetoed[lockId][proposer]`: a challenged proposer may not propose that lockId again; other guardians and the threshold path still can |
| Compromised guardian removed by rotation with proposals pending | n/a | its proposals are void at execute |
| Nobody watching during the window | n/a | the rate limit bounds the loss per window (§4.5.4) |
| Front-running a proposal or an execute | n/a | harmless: `(lockId, amount, to)` is signed; the front-runner pays the gas |
| A guardian challenging every correct proposal (griefing) | n/a | liveness only, no loss: the threshold path still mints; each challenge is a signed, attributable act the set can answer with rotation on Ycash |

**What it does not address.** A quorum of `threshold` keys still mints immediately through
`mint`, and can lift the rate limit. The optimistic path therefore adds a window only if no
single key can use the fast path: **`threshold >= 2` is required wherever the optimistic path is
the security model** (the Foundation's model is then "one attestation + window" for routine
mints and "quorum, immediate" for overrides and admin). `threshold = 1` is a development
setting; `script/Deploy.s.sol` refuses it on mainnet (chain id 1).

#### 4.5.3 Parameters

| Parameter | Where | Constraint | Guidance |
|---|---|---|---|
| `challengeWindow` | constructor, immutable (a change is a successor bridge, §4) | > 0 seconds | longer than Ethereum finality (~13 min) plus the guardians' detection, lock check on Ycash and signing latency; a P8 parameter. Hawkeye's anvil runs use 60 s |
| `mintCap` | constructor; `setMintLimit` | base units per window; 0 = no limit | at most what the set is willing to lose before a human reacts; with `capWindow`, below the YEC the set can slash |
| `capWindow` | constructor; `setMintLimit` | > 0 when `mintCap > 0` | ≥ `challengeWindow`; e.g. one day |
| `threshold` | constructor; `setGuardians` | ≥ 2 on mainnet (above) | a majority |

#### 4.5.4 Rate limit (E-6, resolved)

`mintCap` base units per **fixed** window `floor(block.timestamp / capWindow)`, shared by both
mint paths and applied when the mint happens (`mint`, `executeMint`), not at proposal time. A
proposal over the remaining budget stays `Ready` and executes in a later window. Fixed windows
are one counter and one index, simpler to audit than OpenZeppelin's token bucket; the price is
that the last second of one window and the first of the next can each take a full cap, so the
worst case is `2 × mintCap` within any `capWindow` seconds. `setMintLimit` (threshold-signed,
`SetMintLimit(uint256 mintCap,uint256 capWindow,uint256 adminNonce)`) restarts the running
total: a quorum able to set the cap could raise it anyway. The total is not counted while
`mintCap == 0`.

#### 4.5.5 Cost

Measured on anvil (solc 0.8.37, 200 runs, transaction gas including the 21,000 base):
`proposeMint` 128,346 (first proposal ever; a later one about 111,000), `challengeMint` 38,118
(storage refund included), `executeMint` 134,406 (first mint ever, rate limit on; about 107,000
typical). Deployed size 9,446 bytes (was 5,361); the token is unchanged at 4,683.

## 5. What is deliberately not in the contract

- Any verification of Ycash data (block headers, Equihash, payloads). R2.
- Any release logic. Release, delay, cancel, rate limit and slashing are Ycash consensus (§3).
- A proxy. Successor bridges, not upgrades.
- Transfer pausing or blacklisting.
- Slashing. The Ethereum side stops a bad mint and emits the evidence (§4.5); bonds live on Ycash.

## 6. Open points for the plan (to raise with the owner / Foundation)

| # | Question | Recommendation |
|---|---|---|
| E-1 | Ticker and name of the new token | `wYEC` / "Wrapped Ycash"; WRY keeps its contract and ticker as a legacy asset |
| E-2 | Disposition of WRY | leave alone and name it in the plan; a swap only with the custodian's cooperation and reserve audit |
| E-3 | Successor-bridge path (`setBridge` threshold-signed) vs immutable bridge address | threshold-signed successor; immutable would force a token migration on any bridge defect |
| E-4 | Pause scope | mint+burn only (bridge), never transfers |
| E-5 | `lockId` derivation | daemon convention `sha256(txid‖vout)`; opaque on both sides |
| E-6 | Mint-side rate limit | resolved: fixed-window `mintCap` / `capWindow`, threshold-settable (§4.5.4) |
| E-7 | `ERC20Capped` at 21e6 | include |

## 7. Files in this repository

- The 2021 WRY contract stays in its own repository (boyfromcave/wry) as the deployed reference.
- `contracts/WrappedYcash.sol`: the token (§4).
- `contracts/WyecBridge.sol`: the bridge (§4.1-4.5).
- `foundry.toml`, `package.json`, `package-lock.json`: the Foundry project; OpenZeppelin 5.6.1 and
  forge-std (v1.17.0, commit `f3dae6e`) are exact-pinned npm dependencies.
- `tools/solc`, `tools/solc-shim.js`: a native-`solc` stand-in over the pinned solc-js 0.8.37,
  for machines where Foundry cannot download the compiler (`FOUNDRY_SOLC=./tools/solc`).
- `script/Deploy.s.sol`: the deployment (§8).
- `test/`: the Foundry tests (threshold path, optimistic mint, rate limit, deployment).
- `deployments/<chainid>.json`: written by the deployment; public networks' files are committed.

## 8. Deployment order

The token's constructor takes the bridge address and the bridge's constructor takes the token
address. Deploy the bridge first with the token address **predicted** from the deployer's next
nonce (`CREATE` address = `keccak256(rlp(deployer, nonce))`), then deploy the token in the very
next transaction from the same deployer. `script/Deploy.s.sol` does exactly this and asserts the
prediction before and after; no post-deploy setter is needed, so neither contract has an admin
that could point it somewhere else.

```sh
GUARDIANS=0x…,0x…,0x… THRESHOLD=2 CHALLENGE_WINDOW=3600 MINT_CAP=100000000000 CAP_WINDOW=86400 \
  forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $KEY
```

1. Fix the parameters (§4.5.3): the guardian set registered on Ycash at the bridge-enable height,
   `THRESHOLD` (≥ 2 on mainnet; the script refuses less there), `CHALLENGE_WINDOW`, and
   `MINT_CAP` / `CAP_WINDOW` (default 0 / 0: no limit).
2. Run the script from a fresh deployer; it writes `deployments/<chainid>.json` (bridge, token,
   first possible block, parameters). Commit it for a public network.
3. Each guardian reads back `guardians`, `threshold`, `challengeWindow`, `mintCap`, `capWindow`,
   `token.bridge()` and `bridge.token()` before signing anything for the deployment.

Sizes (forge v1.7.1, solc 0.8.37, optimizer 200 runs): `WyecBridge` 9,446 bytes deployed (5,361
before §4.5), `WrappedYcash` 4,683 bytes; the EIP-170 limit is 24,576.
