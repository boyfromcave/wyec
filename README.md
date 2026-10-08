# wyec

Wrapped Ycash (wYEC): the Ethereum side of the Yellowback upgrade plan's bridge.
Mintable and burnable through a guardian bridge (threshold mint, or optimistic mint with a
challenge window, under an optional rate limit); see `docs/wyec-contract-design.md`.

| Path | What |
|---|---|
| `contracts/WrappedYcash.sol` | the token: OpenZeppelin ERC-20 + ERC-7802, 8 decimals, 21M cap |
| `contracts/WyecBridge.sol` | the bridge: mint (threshold and optimistic), burn, pause, rotation, rate limit, hand-off |
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

Parameters and the mainnet requirements (`THRESHOLD >= 2`): design §4.5.3 and §8.
