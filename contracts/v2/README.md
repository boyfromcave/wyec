# wYEC drafts (plan P5, not yet a repository)

`WrappedYcash.sol` is the token, `WyecBridge.sol` the policy. Design and rationale:
`../../docs/wyec-contract-design.md`. Compile check (OpenZeppelin 5.7.x, solc 0.8.24+):

```sh
npm init -y >/dev/null && npm i --no-audit --no-fund solc@0.8 @openzeppelin/contracts@5
node compile.js .   # compiled clean 2026-10-05: solc 0.8.37, @openzeppelin/contracts 5.6.1
```

The real `wyec/` repository will use Foundry; this is only enough to prove the drafts build.
