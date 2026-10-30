import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { request } from "node:https";
import { join } from "node:path";
import packageJson from "../../package.json" with { type: "json" };
import { getConfigDir } from "./credentials.js";

/** Public, write-only project key: it can send events but read nothing. */
const POSTHOG_KEY = "phc_CLrSgLXTieeMGMXKFff6nYZutjbsjYr0NXlTvmPuT6s";
const POSTHOG_CAPTURE_URL = "https://eu.i.posthog.com/i/v0/e/";
/** Time all events together may spend sending in one run; later events are dropped. */
const BUDGET_MS = 2_000;
const ID_FILE = "telemetry-id";

/** The install funnel, in order, plus the reason a sign-in did not finish. */
export type TelemetryEvent =
  | "mcp_install_started"
  | "mcp_install_logged_in"
  | "mcp_install_login_failed"
  | "mcp_install_completed";

type Properties = Record<string, string | number | boolean | string[]>;

/** Standard OAuth error codes (RFC 6749) and the CLI's own; anything else may echo broker or user text. */
const OAUTH_ERROR_CODES = new Set([
  "invalid_request",
  "invalid_client",
  "invalid_grant",
  "unauthorized_client",
  "unsupported_grant_type",
  "unsupported_response_type",
  "invalid_scope",
  "access_denied",
  "server_error",
  "temporarily_unavailable",
  "invalid_response",
]);

export function oauthFailureReason(code: string): string {
  return OAUTH_ERROR_CODES.has(code) ? code : "oauth_error";
}

function optedOut(value: string | undefined): boolean {
  return Boolean(value) && value !== "0" && value?.toLowerCase() !== "false";
}

/** `DO_NOT_TRACK` (https://consoledonottrack.com) or `SG_NO_TELEMETRY` turns it off. */
export function isTelemetryDisabled(
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  return optedOut(env.DO_NOT_TRACK) || optedOut(env.SG_NO_TELEMETRY);
}

let cachedId: string | undefined;

/** A random ID per machine, so one person's runs line up in the funnel; never tied to the credential. */
export function anonymousId(): string {
  if (cachedId) return cachedId;
  const path = join(getConfigDir(), ID_FILE);
  try {
    const saved = readFileSync(path, "utf-8").trim();
    if (saved) return (cachedId = saved);
  } catch {
    // First run.
  }
  cachedId = randomUUID();
  try {
    mkdirSync(getConfigDir(), { recursive: true, mode: 0o700 });
    writeFileSync(path, `${cachedId}\n`, { encoding: "utf-8", mode: 0o600 });
  } catch {
    // Best effort: an unwritable config dir only splits this run from later ones.
  }
  return cachedId;
}

export function buildPayload(
  event: TelemetryEvent,
  properties: Properties,
  distinctId: string,
): Record<string, unknown> {
  return {
    api_key: POSTHOG_KEY,
    event,
    distinct_id: distinctId,
    timestamp: new Date().toISOString(),
    properties: {
      ...properties,
      cli_version: packageJson.version,
      os: process.platform,
      arch: process.arch,
      // The standalone executable is compiled with Bun; npx runs on Node.
      runtime: process.versions.bun ? "bun" : "node",
      ci: Boolean(process.env.CI),
      $lib: "add-sg-mcp",
      $lib_version: packageJson.version,
      $process_person_profile: false,
    },
  };
}

/**
 * POSTs the body and resolves when the request ends or `timeoutMs` passes.
 * On timeout the socket is destroyed, so a stalled connection or TLS handshake
 * cannot keep the process alive after the CLI is done.
 */
export function send(
  url: string,
  body: string,
  timeoutMs: number,
): Promise<void> {
  return new Promise((resolve) => {
    const req = request(
      url,
      {
        method: "POST",
        agent: false,
        headers: {
          "content-type": "application/json",
          "content-length": Buffer.byteLength(body),
        },
      },
      (res) => res.resume(),
    );
    const timer = setTimeout(() => req.destroy(), timeoutMs);
    req.on("error", () => {});
    req.on("close", () => {
      clearTimeout(timer);
      resolve();
    });
    req.end(body);
  });
}

let spentMs = 0;

/**
 * Sends one event and never throws. Callers await it, so no event is lost to
 * a later `process.exit`; the shared budget caps the delay for the whole run.
 */
export async function track(
  event: TelemetryEvent,
  properties: Properties = {},
): Promise<void> {
  if (isTelemetryDisabled()) return;
  const remaining = BUDGET_MS - spentMs;
  if (remaining <= 0) return;
  const started = Date.now();
  try {
    await send(
      POSTHOG_CAPTURE_URL,
      JSON.stringify(buildPayload(event, properties, anonymousId())),
      remaining,
    );
  } catch {
    // Analytics must never get in the way.
  }
  spentMs += Date.now() - started;
}
