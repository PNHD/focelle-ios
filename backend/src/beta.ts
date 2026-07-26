import { authorized, error, json, readJSON } from "./http";

const DEVICE_ID = /^[A-Za-z0-9_-]{16,64}$/;
const EVENTS = new Set([
  "onboarding_complete",
  "camera_permission_allowed",
  "camera_permission_denied",
  "ai_tap",
  "ai_success",
  "ai_failure",
  "guidance_aligned",
  "capture_after_guidance",
  "filter_save",
  "preset_save",
  "day_1_return",
  "day_7_return",
]);

export async function handleConfig(request: Request, env: Env): Promise<Response> {
  if (request.method !== "GET") return error("METHOD_NOT_ALLOWED", 405);
  if (!await authorized(request, env.APP_SHARED_TOKEN)) return error("AUTH_REQUIRED", 401);
  const deviceId = new URL(request.url).searchParams.get("deviceId") ?? "";
  if (!DEVICE_ID.test(deviceId)) return error("BAD_REQUEST", 400);
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
  if (!isExactObject(value, ["deviceId", "name"])
    || typeof value.deviceId !== "string"
    || !DEVICE_ID.test(value.deviceId)
    || typeof value.name !== "string"
    || !EVENTS.has(value.name)) {
    return error("BAD_REQUEST", 400);
  }

  await env.DB.prepare(
    "INSERT INTO events (device_hash, name) VALUES (?, ?)",
  ).bind(await hash(value.deviceId), value.name).run();
  return json({ ok: true }, 202);
}

export async function recordSuccessfulAnalysis(
  db: D1Database,
  deviceId: string,
): Promise<void> {
  const deviceHash = await hash(deviceId);
  await db.prepare(`
    INSERT INTO beta_devices (device_hash, ai_successes)
    VALUES (?, 1)
    ON CONFLICT(device_hash) DO UPDATE SET
      ai_successes = MIN(3, ai_successes + 1),
      last_seen_at = CURRENT_TIMESTAMP,
      activated_at = CASE
        WHEN activated_at IS NULL AND ai_successes + 1 >= 3 THEN CURRENT_TIMESTAMP
        ELSE activated_at
      END
  `).bind(deviceHash).run();
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
  ).bind(await hash(deviceId)).first<{ ai_successes: number; activated_at: string | null }>();
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

async function hash(value: string): Promise<string> {
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
