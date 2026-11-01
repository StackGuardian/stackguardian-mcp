#!/usr/bin/env tsx
import assert from "node:assert";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { MIN_NODE_MAJOR, nodeVersionError } from "../src/sg/node-version.js";

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    console.log(`✓ ${name}`);
    passed++;
  } catch (err) {
    console.log(`✗ ${name}`);
    console.error(`  ${(err as Error).message}`);
    failed++;
  }
}

const packageJson = JSON.parse(
  readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "..", "package.json"),
    "utf-8",
  ),
);

test("Node versions below the minimum get an error naming both versions", () => {
  for (const version of ["14.21.3", "16.20.2", "17.9.1"]) {
    const error = nodeVersionError(version);
    assert.ok(error, `expected an error for ${version}`);
    assert.ok(error.includes(version));
    assert.ok(error.includes(`Node.js ${MIN_NODE_MAJOR} or later`));
  }
});

test("Node 18 and later pass, including the EOL 18 and 20", () => {
  for (const version of ["18.0.0", "18.20.8", "20.20.2", "22.23.4", "26.0.0"]) {
    assert.strictEqual(nodeVersionError(version), null);
  }
});

test("the minimum matches engines in package.json", () => {
  assert.strictEqual(packageJson.engines.node, `>=${MIN_NODE_MAJOR}`);
});

test("the npm bin is the entry that checks the version", () => {
  assert.strictEqual(packageJson.bin["add-sg-mcp"], "dist/cli.js");
  assert.ok(packageJson.scripts.build.includes("src/cli.ts"));
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
