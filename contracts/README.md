# wYEC contracts (upgrade plan P5)

`WrappedYcash.sol` is the token, `WyecBridge.sol` the policy (threshold mint, optimistic mint,
rate limit, burn, admin). Design and rationale: `../docs/wyec-contract-design.md`.

They are built and tested with Foundry from the repository root (`../foundry.toml`); the tests
are in `../test/`, the deployment script in `../script/Deploy.s.sol`. See `../README.md` for the
commands.
