import { accountForDevice, authenticatedAccount } from "./account";
import { authorized, error, json, readJSON } from "./http";

const CODE_PATTERN = /^[A-Z2-9]{8}$/;

export async function handleReferral(request: Request, env: Env): Promise<Response> {
  if (!await authorized(request, env.APP_SHARED_TOKEN)) return error("AUTH_REQUIRED", 401);
  if (!await enabled(env.DB)) return error("FEATURE_DISABLED", 403);
  const accountId = await authenticatedAccount(request, env.DB);
  if (accountId == null) return error("SESSION_REQUIRED", 401);

  if (request.method === "GET") {
    return json({
      ok: true,
      referral: {
        code: await codeFor(env.DB, accountId),
        ...await referralStatus(env.DB, accountId),
      },
    });
  }
  if (request.method !== "POST") return error("METHOD_NOT_ALLOWED", 405);
  let value: unknown;
  try {
    value = await readJSON(request, 1_024);
  } catch {
    return error("BAD_REQUEST", 400);
  }
  if (!isExactObject(value, ["code"])
    || typeof value.code !== "string"
    || !CODE_PATTERN.test(value.code)) {
    return error("BAD_REQUEST", 400);
  }
  const referrer = await env.DB.prepare(`
    SELECT account_id FROM referral_codes
    WHERE code = ? AND created_at > datetime('now', '-90 days')
  `).bind(value.code).first<{ account_id: number }>();
  if (!referrer) return error("INVALID_REFERRAL", 404);
  if (referrer.account_id === accountId) return error("SELF_REFERRAL", 409);
  try {
    await env.DB.prepare(`
      INSERT INTO referral_claims (
        referred_account_id, referrer_account_id, code
      ) VALUES (?, ?, ?)
    `).bind(accountId, referrer.account_id, value.code).run();
  } catch {
    return error("REFERRAL_ALREADY_USED", 409);
  }
  return json({ ok: true, referral: {
    code: await codeFor(env.DB, accountId),
    ...await referralStatus(env.DB, accountId),
  } });
}

export async function qualifyReferral(
  db: D1Database,
  referredAccountId: number,
  transactionId: string,
  now = new Date(),
): Promise<void> {
  const claim = await db.prepare(`
    SELECT referrer_account_id FROM referral_claims
    WHERE referred_account_id = ?
      AND qualified_transaction_id IS NULL
      AND reversed_at IS NULL
  `).bind(referredAccountId).first<{ referrer_account_id: number }>();
  if (!claim) return;
  const benefitEnds = now.getTime() + 7 * 86_400_000;
  await db.batch([
    db.prepare(`
      UPDATE referral_claims SET
        qualified_transaction_id = ?,
        benefit_ends_at_ms = ?
      WHERE referred_account_id = ? AND qualified_transaction_id IS NULL
    `).bind(transactionId, benefitEnds, referredAccountId),
    db.prepare(`
      INSERT OR IGNORE INTO account_credit_operations (
        idempotency_key, account_id, amount, reason, status
      )
      SELECT ?, referrer_account_id, 30, 'referral', 'consumed'
      FROM referral_claims
      WHERE referred_account_id = ? AND qualified_transaction_id = ?
    `).bind(`referral:${transactionId}`, referredAccountId, transactionId),
  ]);
}

export async function reverseReferral(
  db: D1Database,
  transactionId: string,
): Promise<void> {
  const claim = await db.prepare(`
    SELECT referrer_account_id FROM referral_claims
    WHERE qualified_transaction_id = ? AND reversed_at IS NULL
  `).bind(transactionId).first<{ referrer_account_id: number }>();
  if (!claim) return;
  await db.batch([
    db.prepare(`
      UPDATE referral_claims SET reversed_at = CURRENT_TIMESTAMP
      WHERE qualified_transaction_id = ? AND reversed_at IS NULL
    `).bind(transactionId),
    db.prepare(`
      INSERT OR IGNORE INTO account_credit_operations (
        idempotency_key, account_id, amount, reason, status
      ) VALUES (?, ?, -30, 'revocation', 'consumed')
    `).bind(`referral-reversal:${transactionId}`, claim.referrer_account_id),
  ]);
}

export async function hasActiveReferral(
  db: D1Database,
  deviceHash: string,
  now = new Date(),
): Promise<boolean> {
  const accountId = await accountForDevice(db, deviceHash);
  if (accountId == null) return false;
  const row = await db.prepare(`
    SELECT 1 FROM referral_claims
    WHERE referred_account_id = ?
      AND benefit_ends_at_ms > ?
      AND reversed_at IS NULL
  `).bind(accountId, now.getTime()).first();
  return row != null;
}

async function referralStatus(db: D1Database, accountId: number) {
  const claim = await db.prepare(`
    SELECT qualified_transaction_id, benefit_ends_at_ms, reversed_at
    FROM referral_claims WHERE referred_account_id = ?
  `).bind(accountId).first<{
    qualified_transaction_id: string | null;
    benefit_ends_at_ms: number | null;
    reversed_at: string | null;
  }>();
  return {
    claimed: claim != null,
    qualified: claim?.qualified_transaction_id != null && claim.reversed_at == null,
    benefitEndsAt: claim?.benefit_ends_at_ms ?? null,
  };
}

async function codeFor(db: D1Database, accountId: number): Promise<string> {
  const existing = await db.prepare(
    "SELECT code FROM referral_codes WHERE account_id = ?",
  ).bind(accountId).first<{ code: string }>();
  if (existing) return existing.code;
  for (let attempt = 0; attempt < 3; attempt++) {
    const code = randomCode();
    try {
      await db.prepare(
        "INSERT INTO referral_codes (code, account_id) VALUES (?, ?)",
      ).bind(code, accountId).run();
      return code;
    } catch {
      // Retry the rare code collision.
    }
  }
  throw new Error("code collision");
}

async function enabled(db: D1Database): Promise<boolean> {
  const row = await db.prepare(
    "SELECT value FROM app_config WHERE key = 'referral_enabled'",
  ).first<{ value: string }>();
  return row?.value === "on";
}

function randomCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  return [...bytes].map((byte) => alphabet[byte % alphabet.length]).join("");
}

function isExactObject(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  return typeof value === "object"
    && value !== null
    && !Array.isArray(value)
    && Object.keys(value).length === keys.length
    && keys.every((key) => Object.hasOwn(value, key));
}
