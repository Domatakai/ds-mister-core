// Generate the site's parity/roadmap data from the core's own milestone table.
//
// The landing page's parity matrix is hand-authored prose about subsystems;
// the roadmap's states are not, and neither is the evidence behind each badge.
// This script reads fpga/README.md's milestone table and writes
// src/lib/parity.generated.json, then checks the parity rows:
//
//   node tools/gen-parity.mjs           write the JSON
//   node tools/gen-parity.mjs --check   fail if the JSON is stale, or if a row
//                                       has no evidence or names a milestone the
//                                       core does not have
//
// It cannot judge whether a subsystem badge is true -- that is what AREA.md and
// the benches are for -- but it does stop the file from quietly disagreeing
// with the milestone table it is derived from.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const docPath = join(root, "fpga", "README.md");
const outPath = join(root, "src", "lib", "parity.generated.json");
const lazyPath = join(root, "src", "lib", "parity.ts");

const check = process.argv.includes("--check");

/** rows of the form | M1 | scope | **state** | left | */
function milestones(doc) {
  const out = {};
  for (const line of doc.split("\n")) {
    const m = line.match(/^\|\s*(M\d)\s*\|([^|]*)\|([^|]*)\|([^|]*)\|/);
    if (!m) continue;
    out[m[1]] = {
      id: m[1],
      scope: m[2].trim(),
      state: m[3].replace(/\*/g, "").trim(),
      left: m[4].trim() === "—" ? "" : m[4].trim(),
    };
  }
  return out;
}

const doc = readFileSync(docPath, "utf8");
const states = milestones(doc);
const ids = Object.keys(states);
if (ids.length !== 6) {
  console.error(`expected six milestones in ${docPath}, found ${ids.length}`);
  process.exit(1);
}

const json = JSON.stringify(states, null, 2) + "\n";
const current = existsSync(outPath) ? readFileSync(outPath, "utf8") : "";

if (check) {
  let bad = 0;
  if (current !== json) {
    console.error("parity.generated.json is stale: run `npm run gen:parity`");
    bad++;
  }
  const src = readFileSync(lazyPath, "utf8");
  // every row needs an evidence string, and any milestone it names must exist
  const rows = src.split("name:").slice(1);
  for (const row of rows) {
    const name = (row.match(/^\s*"([^"]*)"/) || [])[1];
    if (!name) continue;
    if (!row.includes("evidence:")) {
      console.error(`parity row "${name}" has no evidence`);
      bad++;
    }
    for (const mm of row.matchAll(/milestone: "(M\d)"/g)) {
      if (!states[mm[1]]) {
        console.error(`parity row "${name}" names ${mm[1]}, which the milestone table does not have`);
        bad++;
      }
    }
  }
  if (bad) process.exit(1);
  console.log(`gen-parity: ${ids.length} milestones, ${rows.length} rows, up to date`);
} else {
  writeFileSync(outPath, json);
  console.log(`gen-parity: wrote ${ids.length} milestones to ${outPath}`);
}
