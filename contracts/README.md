# wYEC contracts (upgrade plan P5)

`WrappedYcash.sol` is the token, `WyecBridge.sol` the policy (threshold mint, optimistic mint,
rate limit, burn, admin). Design and rationale: `../docs/wyec-contract-design.md`.

`burn(uint256 amount, bytes ycashRecipient)` takes the Hawkeye plan §4.2 recipient (revision 2:
22 bytes `02 00|01 <hash160>` for P2PKH / P2SH, 35 bytes `02 02 01|02 <keyHash>` for the
post-quantum `PQPKH` kind) and reverts `InvalidRecipient()` on anything else; `BurnToYcash` carries
the same `bytes`. The former `bytes32` form is retired (design §4.2).

They are built and tested with Foundry from the repository root (`../foundry.toml`); the tests
are in `../test/`, the deployment script in `../script/Deploy.s.sol`. See `../README.md` for the
commands.
