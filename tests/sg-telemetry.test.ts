#!/usr/bin/env tsx
import assert from "node:assert";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  anonymousId,
  buildPayload,
  isTelemetryDisabled,
  track,
} from "../src/sg/telemetry.js";

let passed = 0;
let failed = 0;

async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
    console.log(`✓ ${name}`);
    passed++;
  } catch (err) {
    console.log(`✗ ${name}`);
    console.error(`  ${(err as Error).message}`);
    failed++;
  }
}

const configHome = mkdtempSync(join(tmpdir(), "add-sg-mcp-telemetry-"));
process.env.XDG_CONFIG_HOME = configHome;

await test("telemetry is on without an opt-out", () => {
  assert.strictEqual(isTelemetryDisabled({}), false);
});

await test("DO_NOT_TRACK and SG_NO_TELEMETRY turn it off", () => {
  assert.strictEqual(isTelemetryDisabled({ DO_NOT_TRACK: "1" }), true);
  assert.strictEqual(isTelemetryDisabled({ DO_NOT_TRACK: "true" }), true);
  assert.strictEqual(isTelemetryDisabled({ SG_NO_TELEMETRY: "yes" }), true);
});

await test("0, false and empty do not opt out", () => {
  assert.strictEqual(isTelemetryDisabled({ DO_NOT_TRACK: "0" }), false);
  assert.strictEqual(isTelemetryDisabled({ DO_NOT_TRACK: "false" }), false);
  assert.strictEqual(isTelemetryDisabled({ SG_NO_TELEMETRY: "" }), false);
});

await test("anonymous ID is a UUID saved in the config dir and reused", () => {
  const id = anonymousId();
  assert.match(id, /^[0-9a-f-]{36}$/);
  const saved = readFileSync(
    join(configHome, "add-sg-mcp", "telemetry-id"),
    "utf-8",
  ).trim();
  assert.strictEqual(saved, id);
  assert.strictEqual(anonymousId(), id);
});

await test("payload carries the event, ID, caller properties and context", () => {
  const payload = buildPayload(
    "mcp_install_started",
    { command: "connect" },
    "abc",
  );
  const properties = payload.properties as Record<string, unknown>;
  assert.strictEqual(payload.event, "mcp_install_started");
  assert.strictEqual(payload.distinct_id, "abc");
  assert.match(String(payload.api_key), /^phc_/);
  assert.strictEqual(properties.command, "connect");
  assert.strictEqual(properties.os, process.platform);
  assert.strictEqual(properties.$process_person_profile, false);
  assert.ok(typeof properties.cli_version === "string");
});

await test("caller properties cannot override the context", () => {
  const payload = buildPayload(
    "mcp_install_completed",
    { os: "spoofed" },
    "abc",
  );
  assert.strictEqual(
    (payload.properties as Record<string, unknown>).os,
    process.platform,
  );
});

await test("track resolves without sending when opted out", async () => {
  const before = process.env.DO_NOT_TRACK;
  process.env.DO_NOT_TRACK = "1";
  try {
    await track("mcp_install_started", { command: "connect" });
  } finally {
    if (before === undefined) delete process.env.DO_NOT_TRACK;
    else process.env.DO_NOT_TRACK = before;
  }
});

rmSync(configHome, { recursive: true, force: true });
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
