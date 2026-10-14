# wyec

Wrapped Ycash (wYEC): the Ethereum side of the wYEC bridge in
[Ycash vaults and Yellowback](https://github.com/boyfromcave/yellowback), the proposed Ycash
network upgrade. YEC locked in vaults on Ycash is minted here as wYEC, 1:1; wYEC burned here is
released on Ycash. Mintable and burnable through a guardian bridge (threshold mint, or optimistic
mint with a challenge window, under an optional rate limit); see `docs/wyec-contract-design.md`.
The bridge attestors run [Hawkeye](https://github.com/boyfromcave/hawkeye) against these
contracts.

> **Status: drafts.** Not audited and not deployed. The guardians are the attestors' secp256k1
> keys; the post-quantum keys on the Ycash side (vault owners) never reach these contracts.

| Path | What |
|---|---|
| `contracts/WrappedYcash.sol` | the token: OpenZeppelin ERC-20 + ERC-7802, 8 decimals, 21M cap |
| `contracts/WyecBridge.sol` | the bridge: mint (threshold and optimistic), `burn(uint256, bytes ycashRecipient)` (a validated 22- or 35-byte Ycash recipient, P2PKH / P2SH / post-quantum PQPKH), pause, rotation, rate limit, hand-off |
| `script/Deploy.s.sol` | predicted-address deployment (design §8), writes `deployments/<chainid>.json` |
| `test/` | Foundry tests |
| `tools/solc`, `tools/solc-shim.js` | native-`solc` stand-in over solc-js, for restricted environments |

## Build and test

Foundry v1.7.1 and Node 22. Dependencies (OpenZeppelin 5.6.1, forge-std v1.17.0, solc-js 0.8.37)
are exact-pinned in `package.json` / `package-lock.json`.

```sh
npm ci --ignore-scripts
forge fmt --check
forge build --sizes
forge test -vvv
```

Foundry downloads native solc 0.8.37 as `foundry.toml` asks. Where that download is blocked, use
the solc-js shim instead (same compiler version, identical bytecode):

```sh
export FOUNDRY_SOLC=./tools/solc FOUNDRY_OFFLINE=true
```

## Deploy

```sh
GUARDIANS=0x…,0x…,0x… THRESHOLD=2 CHALLENGE_WINDOW=3600 MINT_CAP=0 CAP_WINDOW=0 \
  forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $KEY
```

Parameters and the mainnet requirements (`THRESHOLD >= 2`, `CHALLENGE_WINDOW >= 7200`, `MINT_CAP > 0`, `MAX_OPEN_PROPOSALS > 0`,
enforced by the constructor and the script on chain id 1): design §4.5.3 and §8.

A **successor bridge** (the only upgrade path) is deployed over the old token with
`OLD_BRIDGE=<old bridge>` (and `PREDECESSOR`, default the old bridge): it inherits the old
bridge's consumed lockIds through `isConsumed`, so no lock mints twice across a migration; the
guardians then sign `setBridge` on the old bridge. Design §4.6.
