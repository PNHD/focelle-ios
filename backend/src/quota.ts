import {
  betaStatus,
  deviceIDPattern,
  hashDevice,
} from "./beta";
import { authorized, error, json, readJSON } from "./http";
import { hasActivePro } from "./store";
import { accountForDevice, creditBalance } from "./account";
import { hasActiveReferral } from "./referral";

export const requestKeyPattern = /^[A-Za-z0-9_-]{16,80}$/;

export async function quotaStatus(
  db: D1Database,
  deviceId: string,
  timezoneOffsetMinutes: number,
  now = new Date(),
): Promise<{
  unlimited: boolean;
  aiRemaining: number;
  filterRemaining: number;
  adsRemaining: number;
  localDay: string;
}> {
  const beta = await betaStatus(db, deviceId, now);
  const localDay = day(now, timezoneOffsetMinutes);
  if (beta.enabled) {
    return {
      unlimited: true,
      aiRemaining: 5,
      filterRemaining: 5,
      adsRemaining: 5,
      localDay,
    };
  }

  const deviceHash = await hashDevice(deviceId);
  if (await hasActivePro(db, deviceHash, now)
    || await hasActiveReferral(db, deviceHash, now)) {
    return {
      unlimited: true,
      aiRemaining: 5,
      filterRemaining: 5,
      adsRemaining: 5,
      localDay,
    };
  }
  const rewards = await db.prepare(`
    SELECT COUNT(*) AS count FROM reward_operations
    WHERE device_hash = ? AND local_day = ?
  `).bind(deviceHash, localDay).first<{ count: number }>();
  const uses = await db.prepare(`
    SELECT kind, COUNT(*) AS count FROM credit_operations
    WHERE device_hash = ? AND local_day = ? AND status IN ('reserved', 'consumed')
    GROUP BY kind
  `).bind(deviceHash, localDay).all<{ kind: "ai" | "filter"; count: number }>();
  const used = Object.fromEntries(uses.results.map(({ kind, count }) => [kind, count]));
  const rewardCount = rewards?.count ?? 0;
  const accountId = await accountForDevice(db, deviceHash);
  const purchased = accountId == null ? 0 : await creditBalance(db, accountId);
  return {
    unlimited: false,
    aiRemaining: Math.max(0, 5 + rewardCount * 3 - (used.ai ?? 0)) + purchased,
    filterRemaining: Math.max(0, 5 + rewardCount * 5 - (used.filter ?? 0)),
    adsRemaining: Math.max(0, 5 - rewardCount),
    localDay,
  };
}

export async function reserveCredit(
  db: D1Database,
  deviceId: string,
  timezoneOffsetMinutes: number,
  kind: "ai" | "filter",
  idempotencyKey: string,
  now = new Date(),
): Promise<{ allowed: boolean; reserved: boolean }> {
  const status = await quotaStatus(db, deviceId, timezoneOffsetMinutes, now);
  if (status.unlimited) return { allowed: true, reserved: false };
  const deviceHash = await hashDevice(deviceId);
  const accountId = await accountForDevice(db, deviceHash);
  const paidExisting = await db.prepare(`
    SELECT account_id, status FROM account_credit_operations
    WHERE idempotency_key = ? AND reason = 'spend'
  `).bind(idempotencyKey).first<{ account_id: number; status: string }>();
  if (paidExisting) {
    return {
      allowed: paidExisting.account_id === accountId && paidExisting.status !== "refunded",
      reserved: paidExisting.status === "reserved",
    };
  }
  const existing = await db.prepare(`
    SELECT device_hash, kind, status FROM credit_operations WHERE idempotency_key = ?
  `).bind(idempotencyKey).first<{
    device_hash: string;
    kind: string;
    status: string;
  }>();
  if (existing) {
    return {
      allowed: existing.device_hash === deviceHash
        && existing.kind === kind
        && existing.status !== "refunded",
      reserved: existing.status === "reserved",
    };
  }
  const remaining = kind === "ai" ? status.aiRemaining : status.filterRemaining;
  if (remaining <= 0) return { allowed: false, reserved: false };

  const result = await db.prepare(`
    INSERT INTO credit_operations
      (idempotency_key, device_hash, local_day, kind, status)
    SELECT ?, ?, ?, ?, 'reserved'
    WHERE (
      SELECT COUNT(*) FROM credit_operations
      WHERE device_hash = ? AND local_day = ? AND kind = ?
        AND status IN ('reserved', 'consumed')
    ) < 5 + (
      SELECT COUNT(*) * CASE WHEN ? = 'ai' THEN 3 ELSE 5 END
      FROM reward_operations
      WHERE device_hash = ? AND local_day = ?
    )
    ON CONFLICT(idempotency_key) DO NOTHING
  `).bind(
    idempotencyKey,
    deviceHash,
    status.localDay,
    kind,
    deviceHash,
    status.localDay,
    kind,
    kind,
    deviceHash,
    status.localDay,
  ).run();
  if ((result.meta.changes ?? 0) === 1) return { allowed: true, reserved: true };
  const concurrent = await db.prepare(`
    SELECT device_hash, kind, status FROM credit_operations WHERE idempotency_key = ?
  `).bind(idempotencyKey).first<{
    device_hash: string;
    kind: string;
    status: string;
  }>();
  if (concurrent) return {
    allowed: concurrent?.device_hash === deviceHash
      && concurrent.kind === kind
      && concurrent.status !== "refunded",
    reserved: concurrent?.status === "reserved",
  };
  if (kind !== "ai" || accountId == null) return { allowed: false, reserved: false };
  const paid = await db.prepare(`
    INSERT INTO account_credit_operations (
      idempotency_key, account_id, amount, reason, status
    )
    SELECT ?, ?, -1, 'spend', 'reserved'
    WHERE (
      SELECT COALESCE(SUM(amount), 0) FROM account_credit_operations
      WHERE account_id = ? AND status IN ('reserved', 'consumed')
    ) > 0
    ON CONFLICT(idempotency_key) DO NOTHING
  `).bind(idempotencyKey, accountId, accountId).run();
  if ((paid.meta.changes ?? 0) === 1) return { allowed: true, reserved: true };
  const paidConcurrent = await db.prepare(`
    SELECT account_id, status FROM account_credit_operations
    WHERE idempotency_key = ? AND reason = 'spend'
  `).bind(idempotencyKey).first<{ account_id: number; status: string }>();
  return {
    allowed: paidConcurrent?.account_id === accountId
      && paidConcurrent.status !== "refunded",
    reserved: paidConcurrent?.status === "reserved",
  };
}

export async function commitCredit(db: D1Database, idempotencyKey: string): Promise<void> {
  await db.batch([
    db.prepare(`
      UPDATE credit_operations SET status = 'consumed'
      WHERE idempotency_key = ? AND status = 'reserved'
    `).bind(idempotencyKey),
    db.prepare(`
      UPDATE account_credit_operations SET status = 'consumed'
      WHERE idempotency_key = ? AND reason = 'spend' AND status = 'reserved'
    `).bind(idempotencyKey),
  ]);
}

export async function refundCredit(db: D1Database, idempotencyKey: string): Promise<void> {
  await db.batch([
    db.prepare(`
      UPDATE credit_operations SET status = 'refunded'
      WHERE idempotency_key = ? AND status = 'reserved'
    `).bind(idempotencyKey),
    db.prepare(`
      UPDATE account_credit_operations SET status = 'refunded'
      WHERE idempotency_key = ? AND reason = 'spend' AND status = 'reserved'
    `).bind(idempotencyKey),
  ]);
}

export async function handleQuota(request: Request, env: Env): Promise<Response> {
  if (!await authorized(request, env.APP_SHARED_TOKEN)) return error("AUTH_REQUIRED", 401);
  if (request.method === "GET") {
    const url = new URL(request.url);
    const deviceId = url.searchParams.get("deviceId") ?? "";
    const timezone = Number(url.searchParams.get("timezoneOffsetMinutes"));
    if (!deviceIDPattern.test(deviceId) || !validTimezone(timezone)) {
      return error("BAD_REQUEST", 400);
    }
    return json({ ok: true, quota: await quotaStatus(env.DB, deviceId, timezone) });
  }
  if (request.method !== "POST") return error("METHOD_NOT_ALLOWED", 405);

  let value: unknown;
  try {
    value = await readJSON(request, 2_048);
  } catch {
    return error("BAD_REQUEST", 400);
  }
  if (!isExactObject(value, ["deviceId", "timezoneOffsetMinutes", "kind", "requestId"])
    || typeof value.deviceId !== "string"
    || !deviceIDPattern.test(value.deviceId)
    || !validTimezone(value.timezoneOffsetMinutes)
    || (value.kind !== "ai" && value.kind !== "filter")
    || typeof value.requestId !== "string"
    || !requestKeyPattern.test(value.requestId)) {
    return error("BAD_REQUEST", 400);
  }
  const reservation = await reserveCredit(
    env.DB,
    value.deviceId,
    value.timezoneOffsetMinutes,
    value.kind,
    value.requestId,
  );
  if (!reservation.allowed) return error("QUOTA_EXHAUSTED", 402);
  await commitCredit(env.DB, value.requestId);
  return json({ ok: true, quota: await quotaStatus(
    env.DB,
    value.deviceId,
    value.timezoneOffsetMinutes,
  ) });
}

export async function handleTestReward(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return error("METHOD_NOT_ALLOWED", 405);
  if (!await authorized(request, env.APP_SHARED_TOKEN)) return error("AUTH_REQUIRED", 401);
  const flag = await env.DB.prepare(
    "SELECT value FROM app_config WHERE key = 'reward_test_enabled'",
  ).first<{ value: string }>();
  if (flag?.value !== "on") return error("FEATURE_DISABLED", 403);

  let value: unknown;
  try {
    value = await readJSON(request, 2_048);
  } catch {
    return error("BAD_REQUEST", 400);
  }
  if (!isExactObject(value, ["deviceId", "timezoneOffsetMinutes", "rewardId"])
    || typeof value.deviceId !== "string"
    || !deviceIDPattern.test(value.deviceId)
    || !validTimezone(value.timezoneOffsetMinutes)
    || typeof value.rewardId !== "string"
    || !requestKeyPattern.test(value.rewardId)) {
    return error("BAD_REQUEST", 400);
  }
  const deviceHash = await hashDevice(value.deviceId);
  const localDay = day(new Date(), value.timezoneOffsetMinutes);
  const result = await env.DB.prepare(`
    INSERT INTO reward_operations (reward_id, device_hash, local_day)
    SELECT ?, ?, ?
    WHERE (
      SELECT COUNT(*) FROM reward_operations
      WHERE device_hash = ? AND local_day = ?
    ) < 5
    ON CONFLICT(reward_id) DO NOTHING
  `).bind(value.rewardId, deviceHash, localDay, deviceHash, localDay).run();
  if ((result.meta.changes ?? 0) === 0) {
    const existing = await env.DB.prepare(
      "SELECT device_hash FROM reward_operations WHERE reward_id = ?",
    ).bind(value.rewardId).first<{ device_hash: string }>();
    if (existing?.device_hash !== deviceHash) return error("REWARD_LIMIT", 429);
  }
  return json({ ok: true, quota: await quotaStatus(
    env.DB,
    value.deviceId,
    value.timezoneOffsetMinutes,
  ) });
}

function day(now: Date, timezoneOffsetMinutes: number): string {
  return new Date(now.getTime() + timezoneOffsetMinutes * 60_000)
    .toISOString()
    .slice(0, 10);
}

export function validTimezone(value: unknown): value is number {
  return typeof value === "number"
    && Number.isInteger(value)
    && value >= -840
    && value <= 840;
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
