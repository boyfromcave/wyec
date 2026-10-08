#!/usr/bin/env node
// A minimal native-`solc` command-line shim over solc-js, for machines where Foundry cannot
// download the native compiler. Foundry only ever calls `solc --version` and
// `solc --standard-json [--base-path P] [--include-path P]... [--allow-paths ...]` with the JSON
// input on stdin, so that is all this implements.
//
// Use it through the `tools/solc` wrapper:  FOUNDRY_SOLC=./tools/solc forge build
// The compiler is the `solc` npm package pinned in package.json (0.8.37), i.e. the same version
// `foundry.toml` names, so the bytecode is identical to a native-solc build.
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
let solc;
try {
  solc = require(path.join(root, 'node_modules', 'solc'));
} catch (e) {
  process.stderr.write('solc-shim: solc-js not installed; run `npm ci --ignore-scripts` at the repository root\n');
  process.exit(1);
}

const args = process.argv.slice(2);

if (args.includes('--version')) {
  // Foundry parses the "Version: x.y.z+commit..." line.
  process.stdout.write('solc, the solidity compiler commandline interface\n');
  process.stdout.write('Version: ' + solc.version() + '\n');
  process.exit(0);
}

if (!args.includes('--standard-json')) {
  process.stderr.write('solc-shim: only --version and --standard-json are supported\n');
  process.exit(2);
}

let base = process.cwd();
const includes = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--base-path') base = args[++i];
  else if (args[i] === '--include-path') includes.push(args[++i]);
}

// Foundry inlines every source's content in the standard JSON, so this callback is a fallback.
function findImports(p) {
  for (const dir of [base, ...includes, process.cwd()]) {
    const f = path.isAbsolute(p) ? p : path.join(dir, p);
    if (fs.existsSync(f)) return { contents: fs.readFileSync(f, 'utf8') };
  }
  return { error: 'File not found: ' + p };
}

const input = fs.readFileSync(0, 'utf8');
process.stdout.write(solc.compile(input, { import: findImports }));
