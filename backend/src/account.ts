import { createRemoteJWKSet, jwtVerify } from "jose";
import { deviceIDPattern, hashDevice } from "./beta";
import { authorized, error, json, readJSON } from "./http";

const APPLE_KEYS = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
const NONCE_PATTERN = /^[A-Za-z0-9_-]{32,128}$/;
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{32,128}$/;

export async function handleAppleLogin(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return error("METHOD_NOT_ALLOWED", 405);
  if (!await authorized(request, env.APP_SHARED_TOKEN)) return error("AUTH_REQUIRED", 401);
  if (!await accountsEnabled(env.DB)) return error("FEATURE_DISABLED", 403);

  let value: unknown;
  try {
    value = await readJSON(request, 20_000);
  } catch {
    return error("BAD_REQUEST", 400);
  }
  if (!isExactObject(value, ["deviceId", "identityToken", "nonce"])
    || typeof value.deviceId !== "string"
    || !deviceIDPattern.test(value.deviceId)
    || typeof value.identityToken !== "string"
    || value.identityToken.length > 16_000
    || typeof value.nonce !== "string"
    || !NONCE_PATTERN.test(value.nonce)) {
    return error("BAD_REQUEST", 400);
  }

  try {
    const expectedNonce = await sha256(value.nonce);
    const { payload } = await jwtVerify(value.identityToken, APPLE_KEYS, {
      issuer: "https://appleid.apple.com",
      audience: "com.pnhd.focelle",
      algorithms: ["RS256"],
    });
    if (typeof payload.sub !== "string" || payload.nonce !== expectedNonce) {
      return error("INVALID_IDENTITY", 401);
    }
    const subjectHash = await sha256(payload.sub);
    await env.DB.prepare(
      "INSERT OR IGNORE INTO accounts (apple_subject_hash) VALUES (?)",
    ).bind(subjectHash).run();
    const account = await env.DB.prepare(
      "SELECT id FROM accounts WHERE apple_subject_hash = ?",
    ).bind(subjectHash).first<{ id: number }>();
    if (!account) return error("ACCOUNT_ERROR", 503);

    const token = randomToken();
    await env.DB.batch([
      env.DB.prepare(`
        INSERT INTO account_sessions (token_hash, account_id, expires_at_ms)
        VALUES (?, ?, ?)
      `).bind(await sha256(token), account.id, Date.now() + 30 * 86_400_000),
      env.DB.prepare(`
        INSERT INTO account_devices (device_hash, account_id)
        VALUES (?, ?)
        ON CONFLICT(device_hash) DO UPDATE SET
          account_id = excluded.account_id,
          updated_at = CURRENT_TIMESTAMP
      `).bind(await hashDevice(value.deviceId), account.id),
    ]);
    return json({ ok: true, sessionToken: token, credits: await creditBalance(env.DB, account.id) });
  } catch {
    return error("INVALID_IDENTITY", 401);
  }
}

export async function handleAccount(request: Request, env: Env): Promise<Response> {
  if (!await authorized(request, env.APP_SHARED_TOKEN)) return error("AUTH_REQUIRED", 401);
  const accountId = await authenticatedAccount(request, env.DB);
  if (accountId == null) return error("SESSION_REQUIRED", 401);
  if (request.method === "GET") {
    return json({ ok: true, credits: await creditBalance(env.DB, accountId) });
  }
  if (request.method !== "DELETE") return error("METHOD_NOT_ALLOWED", 405);
  await env.DB.prepare("DELETE FROM accounts WHERE id = ?").bind(accountId).run();
  return json({ ok: true, credits: 0 });
}

export async function authenticatedAccount(
  request: Request,
  db: D1Database,
): Promise<number | null> {
  const token = request.headers.get("x-focelle-session") ?? "";
  if (!TOKEN_PATTERN.test(token)) return null;
  const session = await db.prepare(`
    SELECT account_id FROM account_sessions
    WHERE token_hash = ? AND expires_at_ms > ?
  `).bind(await sha256(token), Date.now()).first<{ account_id: number }>();
  return session?.account_id ?? null;
}

export async function accountForDevice(
  db: D1Database,
  deviceHash: string,
): Promise<number | null> {
  const row = await db.prepare(
    "SELECT account_id FROM account_devices WHERE device_hash = ?",
  ).bind(deviceHash).first<{ account_id: number }>();
  return row?.account_id ?? null;
}

export async function creditBalance(db: D1Database, accountId: number): Promise<number> {
  const row = await db.prepare(`
    SELECT COALESCE(SUM(amount), 0) AS balance
    FROM account_credit_operations
    WHERE account_id = ? AND status IN ('reserved', 'consumed')
  `).bind(accountId).first<{ balance: number }>();
  return Math.max(0, row?.balance ?? 0);
}

export async function grantCreditPurchase(
  db: D1Database,
  accountId: number,
  transactionId: string,
  amount: number,
): Promise<void> {
  await db.prepare(`
    INSERT OR IGNORE INTO account_credit_operations (
      idempotency_key, account_id, amount, reason, status, transaction_id
    ) VALUES (?, ?, ?, 'purchase', 'consumed', ?)
  `).bind(`purchase:${transactionId}`, accountId, amount, transactionId).run();
}

export async function revokeCreditPurchase(
  db: D1Database,
  transactionId: string,
  amount: number,
): Promise<void> {
  const purchase = await db.prepare(`
    SELECT account_id FROM account_credit_operations
    WHERE transaction_id = ? AND reason = 'purchase'
  `).bind(transactionId).first<{ account_id: number }>();
  if (!purchase) return;
  await db.prepare(`
    INSERT OR IGNORE INTO account_credit_operations (
      idempotency_key, account_id, amount, reason, status
    ) VALUES (?, ?, ?, 'revocation', 'consumed')
  `).bind(`revocation:${transactionId}`, purchase.account_id, -amount).run();
}

async function accountsEnabled(db: D1Database): Promise<boolean> {
  const row = await db.prepare(
    "SELECT value FROM app_config WHERE key = 'accounts_enabled'",
  ).first<{ value: string }>();
  return row?.value === "on";
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function isExactObject(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  return typeof value === "object"
    && value !== null
    && !Array.isArray(value)
    && Object.keys(value).length === keys.length
    && keys.every((key) => Object.hasOwn(value, key));
}
