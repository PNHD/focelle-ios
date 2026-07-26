import {
  Environment,
  type JWSTransactionDecodedPayload,
  SignedDataVerifier,
} from "@apple/app-store-server-library";
import { deviceIDPattern, hashDevice } from "./beta";
import { authorized, error, json, readJSON } from "./http";
import {
  authenticatedAccount,
  grantCreditPurchase,
  revokeCreditPurchase,
} from "./account";

const SUBSCRIPTION_IDS = new Set([
  "com.pnhd.focelle.pro.monthly",
  "com.pnhd.focelle.pro.yearly",
]);
const CREDIT_PACKS = new Map([
  ["com.pnhd.focelle.credits.30", 30],
  ["com.pnhd.focelle.credits.100", 100],
]);
const JWS_PATTERN = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
const APPLE_ROOTS = [
  "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",
].map((value) => Buffer.from(value, "base64"));

export async function handleStoreTransaction(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return error("METHOD_NOT_ALLOWED", 405);
  if (!await authorized(request, env.APP_SHARED_TOKEN)) return error("AUTH_REQUIRED", 401);
  if (!await storeEnabled(env.DB)) return error("FEATURE_DISABLED", 403);

  let value: unknown;
  try {
    value = await readJSON(request, 20_000);
  } catch {
    return error("BAD_REQUEST", 400);
  }
  if (!isExactObject(value, ["deviceId", "signedTransaction"])
    || typeof value.deviceId !== "string"
    || !deviceIDPattern.test(value.deviceId)
    || typeof value.signedTransaction !== "string"
    || value.signedTransaction.length > 16_000
    || !JWS_PATTERN.test(value.signedTransaction)) {
    return error("BAD_REQUEST", 400);
  }

  try {
    const transaction = await verifyTransaction(value.signedTransaction, env);
    const credits = transaction.productId ? CREDIT_PACKS.get(transaction.productId) : undefined;
    if (credits != null) {
      const accountId = await authenticatedAccount(request, env.DB);
      if (accountId == null) return error("SESSION_REQUIRED", 401);
      if (!transaction.transactionId) return error("INVALID_TRANSACTION", 400);
      if (transaction.revocationDate == null) {
        await grantCreditPurchase(env.DB, accountId, transaction.transactionId, credits);
      } else {
        await revokeCreditPurchase(env.DB, transaction.transactionId, credits);
      }
    } else {
      await applyStoreTransaction(env.DB, transaction, await hashDevice(value.deviceId));
    }
    return json({ ok: true }, 202);
  } catch {
    return error("INVALID_TRANSACTION", 400);
  }
}

export async function handleStoreNotification(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return error("METHOD_NOT_ALLOWED", 405);
  if (!await storeEnabled(env.DB)) return error("FEATURE_DISABLED", 403);
  const client = request.headers.get("cf-connecting-ip") ?? "apple";
  if (!(await env.EVENT_RATE_LIMITER.limit({ key: `store:${client}` })).success) {
    return error("RATE_LIMITED", 429);
  }

  let value: unknown;
  try {
    value = await readJSON(request, 40_000);
  } catch {
    return error("BAD_REQUEST", 400);
  }
  if (!isExactObject(value, ["signedPayload"])
    || typeof value.signedPayload !== "string"
    || value.signedPayload.length > 32_000
    || !JWS_PATTERN.test(value.signedPayload)) {
    return error("BAD_REQUEST", 400);
  }

  try {
    const notification = await verifyNotification(value.signedPayload, env);
    const uuid = notification.notificationUUID;
    const signedTransaction = notification.data?.signedTransactionInfo;
    if (!uuid || !signedTransaction) return json({ ok: true });
    const existing = await env.DB.prepare(
      "SELECT 1 FROM store_notifications WHERE notification_uuid = ?",
    ).bind(uuid).first();
    if (existing) return json({ ok: true });

    const transaction = await verifyTransaction(signedTransaction, env);
    const credits = transaction.productId ? CREDIT_PACKS.get(transaction.productId) : undefined;
    if (credits != null) {
      if (transaction.transactionId && transaction.revocationDate != null) {
        await revokeCreditPurchase(env.DB, transaction.transactionId, credits);
      }
    } else {
      await applyStoreTransaction(env.DB, transaction);
    }
    await env.DB.prepare(
      "INSERT OR IGNORE INTO store_notifications (notification_uuid) VALUES (?)",
    ).bind(uuid).run();
    return json({ ok: true });
  } catch {
    return error("INVALID_NOTIFICATION", 400);
  }
}

export async function hasActivePro(
  db: D1Database,
  deviceHash: string,
  now = new Date(),
): Promise<boolean> {
  const row = await db.prepare(`
    SELECT 1 FROM store_transactions
    WHERE device_hash = ? AND revoked_at_ms IS NULL AND expires_at_ms > ?
    LIMIT 1
  `).bind(deviceHash, now.getTime()).first();
  return row != null;
}

export async function applyStoreTransaction(
  db: D1Database,
  transaction: JWSTransactionDecodedPayload,
  suppliedDeviceHash?: string,
): Promise<void> {
  const transactionId = transaction.transactionId;
  const originalId = transaction.originalTransactionId;
  const productId = transaction.productId;
  const expiresAt = transaction.expiresDate;
  const environment = transaction.environment;
  if (!transactionId || !originalId || !productId || !expiresAt || !environment
    || !SUBSCRIPTION_IDS.has(productId)) {
    throw new Error("invalid subscription transaction");
  }
  const existing = await db.prepare(`
    SELECT device_hash FROM store_transactions
    WHERE original_transaction_id = ? AND device_hash IS NOT NULL
    LIMIT 1
  `).bind(originalId).first<{ device_hash: string }>();
  const deviceHash = suppliedDeviceHash ?? existing?.device_hash ?? null;
  await db.prepare(`
    INSERT INTO store_transactions (
      transaction_id, original_transaction_id, device_hash, product_id,
      environment, expires_at_ms, revoked_at_ms
    ) VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(transaction_id) DO UPDATE SET
      device_hash = COALESCE(excluded.device_hash, device_hash),
      expires_at_ms = excluded.expires_at_ms,
      revoked_at_ms = excluded.revoked_at_ms,
      updated_at = CURRENT_TIMESTAMP
  `).bind(
    transactionId,
    originalId,
    deviceHash,
    productId,
    environment,
    expiresAt,
    transaction.revocationDate ?? null,
  ).run();
}

async function storeEnabled(db: D1Database): Promise<boolean> {
  const row = await db.prepare(`
    SELECT COUNT(*) AS count FROM app_config
    WHERE key IN ('store_sandbox_enabled', 'store_production_enabled') AND value = 'on'
  `).first<{ count: number }>();
  return (row?.count ?? 0) > 0;
}

async function verifyTransaction(signed: string, env: Env) {
  for (const verifier of await verifiers(env)) {
    try {
      return await verifier.verifyAndDecodeTransaction(signed);
    } catch {
      // Try only explicitly enabled App Store environments.
    }
  }
  throw new Error("verification failed");
}

async function verifyNotification(signed: string, env: Env) {
  for (const verifier of await verifiers(env)) {
    try {
      return await verifier.verifyAndDecodeNotification(signed);
    } catch {
      // Try only explicitly enabled App Store environments.
    }
  }
  throw new Error("verification failed");
}

async function verifiers(env: Env): Promise<SignedDataVerifier[]> {
  const rows = await env.DB.prepare(`
    SELECT key, value FROM app_config
    WHERE key IN ('store_sandbox_enabled', 'store_production_enabled')
  `).all<{ key: string; value: string }>();
  const config = Object.fromEntries(rows.results.map(({ key, value }) => [key, value]));
  const result: SignedDataVerifier[] = [];
  if (config.store_sandbox_enabled === "on") {
    result.push(new SignedDataVerifier(
      APPLE_ROOTS,
      true,
      Environment.SANDBOX,
      "com.pnhd.focelle",
    ));
  }
  const appAppleId = Number(env.APP_APPLE_ID);
  if (config.store_production_enabled === "on"
    && Number.isSafeInteger(appAppleId)
    && appAppleId > 0) {
    result.push(new SignedDataVerifier(
      APPLE_ROOTS,
      true,
      Environment.PRODUCTION,
      "com.pnhd.focelle",
      appAppleId,
    ));
  }
  return result;
}

function isExactObject(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  return typeof value === "object"
    && value !== null
    && !Array.isArray(value)
    && Object.keys(value).length === keys.length
    && keys.every((key) => Object.hasOwn(value, key));
}
