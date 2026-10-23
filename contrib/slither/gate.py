#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Triage Slither's results for CI (SECURITY-CI.md, "Slither"). Stdlib only.

  contrib/slither/gate.py --json slither.json --sarif slither.sarif --out DIR [--enforce]

Reads Slither's --json and --sarif output and contrib/slither/accepted.json, and writes to DIR:
  results.sarif  Slither's SARIF without the accepted results, each result fingerprinted stably
                 (check + the elements' names and files, no line numbers), for code scanning
  summary.md     a table of every result: impact, confidence, check, location, accepted or open

A result *gates* when its impact is High, or Medium with High confidence (config "fail_on" below).
--enforce exits 1 when a gating result is not accepted: on a PR, every pre-existing gating result is
in accepted.json, so that is "the PR adds one". Accept a result by its fingerprint (summary.md), with a
reason a reviewer can check, never by editing the contract under review in the same breath.
"""

import argparse
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FAIL_ON = {("High", "High"), ("High", "Medium"), ("High", "Low"), ("Medium", "High")}


def fingerprint(result):
    parts = [result["check"]]
    for e in result.get("elements", []):
        parent = e.get("type_specific_fields", {}).get("parent", {})
        parts.append("%s:%s:%s:%s" % (e.get("type"), e.get("name"), parent.get("name", ""),
                                      e.get("source_mapping", {}).get("filename_relative", "")))
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:16]


def location(result):
    md = result.get("first_markdown_element", "")
    return md.replace("#L", ":").split("-L")[0] if md else "?"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", required=True)
    ap.add_argument("--sarif", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--accepted", default=os.path.join(HERE, "accepted.json"))
    ap.add_argument("--enforce", action="store_true")
    args = ap.parse_args()

    with open(args.json, encoding="utf-8") as f:
        report = json.load(f)
    if not report.get("success", False):
        sys.exit("gate.py: slither did not succeed: %s" % report.get("error"))
    with open(args.accepted, encoding="utf-8") as f:
        accepted = json.load(f)["findings"]
    results = report.get("results", {}).get("detectors", [])

    by_id = {}
    rows = []
    open_gating = []
    for r in results:
        fp = fingerprint(r)
        by_id[r["id"]] = fp
        gating = (r["impact"], r["confidence"]) in FAIL_ON
        status = "accepted" if fp in accepted else ("**OPEN, gates**" if gating else "open")
        if gating and fp not in accepted:
            open_gating.append(r)
        rows.append((r["impact"], r["confidence"], r["check"], location(r), fp, status))

    with open(args.sarif, encoding="utf-8") as f:
        sarif = json.load(f)
    for run in sarif.get("runs", []):
        kept = []
        for res in run.get("results", []):
            fp = by_id.get(res.get("partialFingerprints", {}).get("id"))
            if fp in accepted:
                continue
            if fp:
                res["partialFingerprints"] = {"wyecSlither/v1": fp}
            kept.append(res)
        run["results"] = kept

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "results.sarif"), "w", encoding="utf-8") as f:
        json.dump(sarif, f, indent=1)
    order = {"High": 0, "Medium": 1, "Low": 2, "Informational": 3, "Optimization": 4}
    rows.sort(key=lambda x: (order.get(x[0], 9), order.get(x[1], 9), x[2], x[3]))
    lines = ["## Slither", "",
             "%d results, %d accepted (contrib/slither/accepted.json), %d open that gate (High impact, or "
             "Medium impact with High confidence)." % (len(rows), sum(1 for x in rows if x[5] == "accepted"),
                                                         len(open_gating)), "",
             "| Impact | Confidence | Check | Location | Fingerprint | Status |", "|---|---|---|---|---|---|"]
    lines += ["| %s | %s | `%s` | `%s` | `%s` | %s |" % row for row in rows]
    with open(os.path.join(args.out, "summary.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))

    stale = sorted(set(accepted) - set(by_id.values()))
    if stale:
        print("\ngate.py: accepted.json entries no result matched (fixed, or the code changed): %s" % ", ".join(stale))
    if args.enforce and open_gating:
        for r in open_gating:
            print("gate.py: %s/%s %s at %s is not accepted" % (r["impact"], r["confidence"], r["check"], location(r)),
                  file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
