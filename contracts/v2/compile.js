const solc = require('solc'); const fs = require('fs'); const path = require('path');
const dir = process.argv[2];
const sources = {};
for (const f of ['WrappedYcash.sol','WyecBridge.sol']) sources[f] = { content: fs.readFileSync(path.join(dir,f),'utf8') };
function findImports(p){ try { return { contents: fs.readFileSync(path.join('node_modules',p),'utf8') }; } catch(e){ return { error:'not found '+p }; } }
const input = { language:'Solidity', sources, settings:{ optimizer:{enabled:true,runs:200}, outputSelection:{'*':{'*':['abi','evm.bytecode.object','evm.deployedBytecode.object']}} } };
const out = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
let bad=false;
for (const e of out.errors||[]) { console.log(e.severity.toUpperCase()+': '+e.formattedMessage); if (e.severity==='error') bad=true; }
if (!bad) for (const f in out.contracts) for (const c in out.contracts[f]) { const o=out.contracts[f][c]; console.log(f, c, 'deployed bytes:', o.evm.deployedBytecode.object.length/2, 'fns:', o.abi.filter(a=>a.type==='function').map(a=>a.name).join(',')); }
process.exit(bad?1:0);
