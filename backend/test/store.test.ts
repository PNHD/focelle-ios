import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { hashDevice } from "../src/beta";
import { quotaStatus } from "../src/quota";
import { applyStoreTransaction, hasActivePro } from "../src/store";

const deviceId = "device_1234567890";
const deviceHash = await hashDevice(deviceId);
const now = new Date("2026-07-26T12:00:00Z");

beforeEach(async () => {
  await env.DB.prepare("DELETE FROM store_transactions").run();
  await env.DB.prepare("DELETE FROM store_notifications").run();
  await env.DB.prepare(
    "UPDATE app_config SET value = 'off' WHERE key = 'beta_force'",
  ).run();
});

describe("verified subscription state", () => {
  it("is idempotent, follows renewals, and removes revoked access", async () => {
    await applyStoreTransaction(env.DB, transaction("tx-1", now.getTime() + 60_000), deviceHash);
    await applyStoreTransaction(env.DB, transaction("tx-1", now.getTime() + 60_000), deviceHash);
    expect(await hasActivePro(env.DB, deviceHash, now)).toBe(true);
    expect((await quotaStatus(env.DB, deviceId, 420, now)).unlimited).toBe(true);

    await applyStoreTransaction(env.DB, transaction("tx-2", now.getTime() + 120_000));
    await applyStoreTransaction(env.DB, {
      ...transaction("tx-1", now.getTime() + 60_000),
      revocationDate: now.getTime(),
    });
    expect(await hasActivePro(env.DB, deviceHash, now)).toBe(true);

    await applyStoreTransaction(env.DB, {
      ...transaction("tx-2", now.getTime() + 120_000),
      revocationDate: now.getTime(),
    });
    expect(await hasActivePro(env.DB, deviceHash, now)).toBe(false);
    const count = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM store_transactions",
    ).first<{ count: number }>();
    expect(count?.count).toBe(2);
  });

  it("rejects unknown products and expired subscriptions", async () => {
    await applyStoreTransaction(env.DB, transaction("tx-1", now.getTime() - 1), deviceHash);
    expect(await hasActivePro(env.DB, deviceHash, now)).toBe(false);
    await expect(applyStoreTransaction(env.DB, {
      ...transaction("tx-2", now.getTime() + 60_000),
      productId: "unknown",
    }, deviceHash)).rejects.toThrow();
  });
});

function transaction(transactionId: string, expiresDate: number) {
  return {
    transactionId,
    originalTransactionId: "original-1",
    productId: "com.pnhd.focelle.pro.monthly",
    environment: "Sandbox",
    expiresDate,
  };
}
