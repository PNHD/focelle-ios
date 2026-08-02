import { authorized, error, json, readJSON } from "./http";

export const deviceIDPattern = /^[A-Za-z0-9_-]{16,64}$/;
const EVENTS = new Set([
  "onboarding_complete",
  "camera_permission_allowed",
  "camera_permission_denied",
  "ai_tap",
  "ai_success",
  "ai_failure",
  "guidance_aligned",
  "ai_alternative_selected",
  "capture_after_guidance",
  "filter_selected",
  "preset_selected",
  "filter_save",
  "preset_save",
  "activation",
  "day_1_return",
  "day_7_return",
  "reward_completion",
  "purchase",
  "restore",
  "referral_outcome",
]);
const EVENT_CATEGORIES = new Set([
  "success",
  "failed",
  "subscription",
  "credit",
  "unavailable",
  "offline",
  "timed_out",
  "rate_limited",
  "invalid_response",
  "quota_exhausted",
  "server",
]);
const LATENCY_BUCKETS = new Set(["under_3s", "3_to_8s", "over_8s"]);

export async function handleConfig(request: Request, env: Env): Promise<Response> {
  if (request.method !== "GET") return error("METHOD_NOT_ALLOWED", 405);
  if (!await authorized(request, env.APP_SHARED_TOKEN)) return error("AUTH_REQUIRED", 401);
  const deviceId = new URL(request.url).searchParams.get("deviceId") ?? "";
  if (!deviceIDPattern.test(deviceId)) return error("BAD_REQUEST", 400);
  if (!(await env.EVENT_RATE_LIMITER.limit({ key: deviceId })).success) {
    return error("RATE_LIMITED", 429);
  }
  return json({ ok: true, beta: await betaStatus(env.DB, deviceId) });
}

export async function handleEvent(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return error("METHOD_NOT_ALLOWED", 405);
  if (!await authorized(request, env.APP_SHARED_TOKEN)) return error("AUTH_REQUIRED", 401);
  const client = request.headers.get("cf-connecting-ip") ?? "local";
  if (!(await env.EVENT_RATE_LIMITER.limit({ key: client })).success) {
    return error("RATE_LIMITED", 429);
  }

  let value: unknown;
  try {
    value = await readJSON(request, 2_048);
  } catch {
    return error("BAD_REQUEST", 400);
  }
  if (!isEvent(value)
    || typeof value.deviceId !== "string"
    || !deviceIDPattern.test(value.deviceId)
    || typeof value.name !== "string"
    || !EVENTS.has(value.name)
    || (value.category !== undefined
      && (typeof value.category !== "string" || !EVENT_CATEGORIES.has(value.category)))
    || (value.latencyBucket !== undefined
      && (typeof value.latencyBucket !== "string"
        || !LATENCY_BUCKETS.has(value.latencyBucket)))
    || (value.schemaVersion !== undefined
      && (typeof value.schemaVersion !== "number"
        || !Number.isInteger(value.schemaVersion)
        || value.schemaVersion < 1
        || value.schemaVersion > 100))) {
    return error("BAD_REQUEST", 400);
  }

  await env.DB.prepare(`
    INSERT OR IGNORE INTO events (
      device_hash, name, category, latency_bucket, schema_version
    ) VALUES (?, ?, ?, ?, ?)
  `).bind(
    await hashDevice(value.deviceId),
    value.name,
    value.category ?? null,
    value.latencyBucket ?? null,
    value.schemaVersion ?? null,
  ).run();
  return json({ ok: true }, 202);
}

export async function recordSuccessfulAnalysis(
  db: D1Database,
  deviceId: string,
): Promise<void> {
  const deviceHash = await hashDevice(deviceId);
  await db.batch([
    db.prepare(`
      INSERT INTO beta_devices (device_hash, ai_successes)
      VALUES (?, 1)
      ON CONFLICT(device_hash) DO UPDATE SET
        ai_successes = MIN(3, ai_successes + 1),
        last_seen_at = CURRENT_TIMESTAMP,
        activated_at = CASE
          WHEN activated_at IS NULL AND ai_successes + 1 >= 3 THEN CURRENT_TIMESTAMP
          ELSE activated_at
        END
    `).bind(deviceHash),
    db.prepare(`
      INSERT OR IGNORE INTO events (device_hash, name)
      SELECT device_hash, 'activation' FROM beta_devices
      WHERE device_hash = ? AND activated_at IS NOT NULL
    `).bind(deviceHash),
  ]);
}

export async function betaStatus(
  db: D1Database,
  deviceId: string,
  now = new Date(),
): Promise<{
  enabled: boolean;
  activated: boolean;
  successfulAnalyses: number;
  endsAt: string;
  activatedUsers: number;
}> {
  const rows = await db.prepare(
    "SELECT key, value FROM app_config",
  ).all<{ key: string; value: string }>();
  const config = Object.fromEntries(rows.results.map(({ key, value }) => [key, value]));
  const configuredStart = new Date(config.beta_started_at ?? "");
  const started = Number.isNaN(configuredStart.getTime()) ? now : configuredStart;
  const duration = boundedInteger(config.beta_duration_days, 60);
  const maximum = boundedInteger(config.beta_max_activations, 500);
  const endsAt = new Date(started.getTime() + duration * 86_400_000);
  const count = await db.prepare(
    "SELECT COUNT(*) AS count FROM beta_devices WHERE activated_at IS NOT NULL",
  ).first<{ count: number }>();
  const device = await db.prepare(
    "SELECT ai_successes, activated_at FROM beta_devices WHERE device_hash = ?",
  ).bind(await hashDevice(deviceId)).first<{ ai_successes: number; activated_at: string | null }>();
  const force = config.beta_force ?? "auto";
  const enabled = force === "on"
    || (force !== "off" && now < endsAt && (count?.count ?? 0) < maximum);

  return {
    enabled,
    activated: device?.activated_at != null,
    successfulAnalyses: device?.ai_successes ?? 0,
    endsAt: endsAt.toISOString(),
    activatedUsers: count?.count ?? 0,
  };
}

export async function hashDevice(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function boundedInteger(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function isExactObject(
  value: unknown,
  keys: readonly string[],
): value is Record<string, unknown> {
  return typeof value === "object"
    && value !== null
    && !Array.isArray(value)
    && Object.keys(value).length === keys.length
    && keys.every((key) => Object.hasOwn(value, key));
}

function isEvent(value: unknown): value is {
  deviceId: unknown;
  name: unknown;
  category?: unknown;
  latencyBucket?: unknown;
  schemaVersion?: unknown;
} {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const allowed = new Set([
    "deviceId",
    "name",
    "category",
    "latencyBucket",
    "schemaVersion",
  ]);
  return Object.hasOwn(value, "deviceId")
    && Object.hasOwn(value, "name")
    && Object.keys(value).every((key) => allowed.has(key));
}
