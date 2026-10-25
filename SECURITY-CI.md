# Security CI

wYEC's contracts will hold bridged value, so every push, every PR and every night runs the checks
below. There are four workflows: `semgrep.yml`, `codeql.yml`, `secops.yml` and `code-scanning.yml`. Every tool is
installed at an exact version, checked against a sha256 recorded in the workflow or installed from a
hash-locked requirements file. Every action is pinned to a commit SHA. No check opens an issue. Only
Semgrep opens PRs: at most four rolling ones, one per severity bucket.

| Leg | Workflow / job | Runs on | Fails when | Results |
|---|---|---|---|---|
| **Slither** (primary Solidity analyzer) | `secops.yml` `slither` | PR, push to `upgrade/vault`, nightly 03:43 UTC, dispatch | a PR adds a result with High impact, or Medium impact and High confidence, that `contrib/slither/accepted.json` does not accept | step summary, artifact, code scanning (`slither`) |
| **Aderyn** (second Solidity analyzer) | `secops.yml` `aderyn` | same | never (report only) | step summary, artifact (`report.md`) |
| **Semgrep** | `semgrep.yml` | PR (diff-aware), every push, nightly 02:17 UTC | a PR adds a `critical` finding | step summary, artifact, code scanning (`semgrep`), rolling `semgrep/<bucket>` PRs |
| **CodeQL** (Actions, JavaScript) | `codeql.yml` | PR, push to `upgrade/vault`, weekly | never on alerts that already exist | code scanning |
| **zizmor** (workflow security) | `secops.yml` `zizmor` | PR, push, nightly | any finding in `.github/` | code scanning (`zizmor`) |
| **gitleaks** (secrets) | `secops.yml` `gitleaks` | PR: the PR's commits. Push, nightly, dispatch: full history | a leak | code scanning (`gitleaks`), with values redacted |
| **OSV-Scanner** | `secops.yml` `osv-scanner` | PR, push, nightly | a known vulnerability in `package-lock.json` or one of the `contrib/*/requirements.txt` locks that `osv-scanner.toml` does not ignore | step summary, code scanning (`osv-scanner`) |
| **npm audit** | `secops.yml` `npm-audit` | PR, push, nightly | a high or critical advisory in a production npm dependency | job log |
| **Code-scanning triage** | `code-scanning.yml` (`contrib/secops/code-scanning-triage.py`) | push to `upgrade/vault` that changes the ledger or the workflow, nightly 03:53 UTC, dispatch (`dry_run` only prints) | never on an open alert | dismisses the alerts listed in `contrib/secops/code-scanning-dismissals.json`; run summary (alerts left open), artifact `code-scanning-alerts` |
| **Dependabot** | `.github/dependabot.yml` | GitHub | (security updates only) | at most one grouped PR per ecosystem (npm, github-actions) |

## Slither

`slither.config.json` sets the scope. Slither builds with Foundry (`forge build`, solc 0.8.37 from
`foundry.toml`) and analyses `contracts/`, leaving out `test/`, `script/` and `node_modules/`.
Informational and optimization results are left out. Slither is installed from
`contrib/slither/requirements.txt`. `contrib/slither/gate.py` triages the results:

- it gives each result a fingerprint built from the check and the names and files of the flagged
  elements, with no line numbers, so moving code does not reopen a result but editing the flagged
  code does;
- it removes accepted results from the SARIF it uploads, and lists every result in `summary.md`;
- with `--enforce`, which only PRs use, it fails on an open result that gates.

Run it locally like this (where the native solc download is blocked, also set `FOUNDRY_SOLC`, see
README):

```sh
npm ci --ignore-scripts
python3 -m venv .venv-slither && .venv-slither/bin/pip install --require-hashes --no-deps -r contrib/slither/requirements.txt
.venv-slither/bin/slither . --fail-none --json /tmp/s.json --sarif /tmp/s.sarif
python3 contrib/slither/gate.py --json /tmp/s.json --sarif /tmp/s.sarif --out /tmp/slither-out --enforce
```

## Aderyn

Aderyn is report only. Its SARIF has byte offsets but no line numbers, so it does not go to code
scanning. Read the step summary or the `aderyn` artifact. Its findings at setup (2026-10-23) were all
triaged as not exploitable:

- `reentrancy-state-change` in `burn`: the call goes to the immutable, hook-free `token`;
- `state-change-without-event` in `setBridge`: the token emits `BridgeChanged`;
- the rest are low-severity style checks (literals, pragma, loops).

## Semgrep

See `contrib/semgrep/README.md`. The rule packs are fetched at pinned commits:
[semgrep-rules](https://github.com/semgrep/semgrep-rules) `solidity/security`, JavaScript, bash,
secrets and GitHub Actions; [Trail of Bits](https://github.com/trailofbits/semgrep-rules) generic
and GitHub Actions; and [Decurity](https://github.com/Decurity/semgrep-smart-contracts)
`solidity/security`. Decurity's rules are CC BY-NC-SA 4.0: they are used for our own scans and
never copied into this repository.

The bridge's own invariants are in `contrib/semgrep/rules/wyec.yaml`, with tests in `wyec.sol`
(`semgrep --test contrib/semgrep/rules`):

| Rule | Bucket | Invariant |
|---|---|---|
| `wyec.auth.tx-origin` | critical | no `tx.origin` authorisation |
| `wyec.call.unchecked-low-level-call` | high | no `call` / `delegatecall` / `staticcall` / `send` whose success flag is discarded |
| `wyec.sig.recover-outside-eip712-domain` | critical | every signature is recovered over a digest built by `_hashTypedDataV4` (directly or via `mintDigest` / `challengeDigest`); no raw `ecrecover` |
| `wyec.sig.threshold-outside-eip712-domain` | critical | every `_checkThreshold` digest is built the same way |

## Accepting a finding

A finding is either fixed, or accepted with a reason a reviewer can check. A blanket disable is
never the answer. Where each tool's acceptances go:

| Tool | Where | Key |
|---|---|---|
| Slither | `contrib/slither/accepted.json` | the fingerprint from `summary.md`, with `check`, `where`, `reason`, `by`, `date` |
| Semgrep | `contrib/semgrep/accepted.json` | the fingerprint, or `rule_paths` for a rule over paths (see its README) |
| OSV-Scanner | `osv-scanner.toml` `[[IgnoredVulns]]` | advisory id, `reason`, `ignoreUntil` no more than 90 days out |
| gitleaks | `.gitleaksignore` | the finding's fingerprint plus a comment. Only for test vectors and public constants: a real secret is rotated, never ignored |
| Code scanning (CodeQL and every SARIF upload) | `contrib/secops/code-scanning-dismissals.json` | tool, rule, path glob, reason `false positive` / `won't fix` / `used in tests`, and a comment of at most 280 characters with the argument; `code-scanning.yml` dismisses the matching alerts on a push to `upgrade/vault` that changes the file and nightly, so the decision is in the history rather than only in the web UI. Check a new entry with the workflow's `dry_run` dispatch |
| zizmor | inline `# zizmor: ignore[<audit>]` with a reason | fix it instead wherever possible |

Contract changes keep their own review: never "fix" a contract only to quiet a scanner. Hawkeye
fetches these contracts at a pinned commit, and an encoding change goes through its plan first.

## Repository settings (owner)

- *Settings → Code security*: enable code scanning (free on public repositories), Dependabot
  alerts and Dependabot security updates.
- Semgrep's rolling PRs need *Settings → Actions → General → Allow GitHub Actions to create and
  approve pull requests*. To have CI run on those PRs, add a `SEMGREP_PR_TOKEN` secret
  (contents and pull requests: write).
