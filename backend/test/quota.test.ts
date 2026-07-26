import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  handleTestReward,
  quotaStatus,
  refundCredit,
  reserveCredit,
} from "../src/quota";
import { creditBalance, grantCreditPurchase } from "../src/account";
import { hashDevice } from "../src/beta";

const deviceId = "device_1234567890";
const now = new Date("2026-07-26T12:00:00Z");

beforeEach(async () => {
  await env.DB.prepare("DELETE FROM credit_operations").run();
  await env.DB.prepare("DELETE FROM reward_operations").run();
  await env.DB.prepare("DELETE FROM account_credit_operations").run();
  await env.DB.prepare("DELETE FROM account_devices").run();
  await env.DB.prepare("DELETE FROM account_sessions").run();
  await env.DB.prepare("DELETE FROM accounts").run();
  await env.DB.prepare(
    "UPDATE app_config SET value = 'off' WHERE key = 'beta_force'",
  ).run();
  await env.DB.prepare(
    "UPDATE app_config SET value = 'off' WHERE key = 'reward_test_enabled'",
  ).run();
});

describe("daily quota", () => {
  it("allows five uses, refunds failures, and keeps retries idempotent", async () => {
    for (let index = 0; index < 5; index++) {
      expect((await reserveCredit(
        env.DB,
        deviceId,
        420,
        "ai",
        key(index),
        now,
      )).allowed).toBe(true);
    }
    expect((await reserveCredit(
      env.DB,
      deviceId,
      420,
      "ai",
      key(5),
      now,
    )).allowed).toBe(false);
    expect((await reserveCredit(
      env.DB,
      deviceId,
      420,
      "ai",
      key(0),
      now,
    )).allowed).toBe(true);

    await refundCredit(env.DB, key(0));
    expect((await reserveCredit(
      env.DB,
      deviceId,
      420,
      "ai",
      key(5),
      now,
    )).allowed).toBe(true);
  });

  it("does not overdraw during concurrent reservations", async () => {
    const results = await Promise.all(Array.from({ length: 10 }, (_, index) =>
      reserveCredit(env.DB, deviceId, 420, "filter", key(index), now)));
    expect(results.filter(({ allowed }) => allowed)).toHaveLength(5);
    expect((await quotaStatus(env.DB, deviceId, 420, now)).filterRemaining).toBe(0);
  });

  it("resets on the next local calendar day", async () => {
    await reserveCredit(env.DB, deviceId, 420, "ai", key(0), now);
    const tomorrow = new Date("2026-07-27T12:00:00Z");
    expect((await quotaStatus(env.DB, deviceId, 420, tomorrow)).aiRemaining).toBe(5);
  });

  it("uses synced purchased AI credits only after the daily allowance", async () => {
    const created = await env.DB.prepare(
      "INSERT INTO accounts (apple_subject_hash) VALUES ('subject') RETURNING id",
    ).first<{ id: number }>();
    await env.DB.prepare(
      "INSERT INTO account_devices (device_hash, account_id) VALUES (?, ?)",
    ).bind(await hashDevice(deviceId), created!.id).run();
    await grantCreditPurchase(env.DB, created!.id, "purchase-1", 2);

    for (let index = 0; index < 7; index++) {
      expect((await reserveCredit(
        env.DB,
        deviceId,
        420,
        "ai",
        key(index),
        now,
      )).allowed).toBe(true);
    }
    expect((await reserveCredit(
      env.DB,
      deviceId,
      420,
      "ai",
      key(7),
      now,
    )).allowed).toBe(false);
    expect(await creditBalance(env.DB, created!.id)).toBe(0);

    await refundCredit(env.DB, key(6));
    expect(await creditBalance(env.DB, created!.id)).toBe(1);
  });
});

describe("test rewards", () => {
  it("is remotely disabled and caps idempotent grants at five", async () => {
    expect((await handleTestReward(rewardRequest("reward_0000000000000001"), env)).status)
      .toBe(403);
    await env.DB.prepare(
      "UPDATE app_config SET value = 'on' WHERE key = 'reward_test_enabled'",
    ).run();

    for (let index = 0; index < 5; index++) {
      expect((await handleTestReward(rewardRequest(key(index)), env)).status).toBe(200);
    }
    expect((await handleTestReward(rewardRequest(key(0)), env)).status).toBe(200);
    expect((await handleTestReward(rewardRequest(key(6)), env)).status).toBe(429);
    const status = await quotaStatus(env.DB, deviceId, 420);
    expect(status.aiRemaining).toBe(20);
    expect(status.filterRemaining).toBe(30);
    expect(status.adsRemaining).toBe(0);
  });
});

function key(index: number): string {
  return `request_${String(index).padStart(16, "0")}`;
}

function rewardRequest(rewardId: string): Request {
  return new Request("https://test/v1/rewards/test", {
    method: "POST",
    headers: {
      authorization: "Bearer test-token",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      deviceId,
      timezoneOffsetMinutes: 420,
      rewardId,
    }),
  });
}
