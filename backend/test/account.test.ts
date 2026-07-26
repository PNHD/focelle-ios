import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  accountForDevice,
  creditBalance,
  grantCreditPurchase,
  handleAccount,
  handleAppleLogin,
  revokeCreditPurchase,
} from "../src/account";

beforeEach(async () => {
  await env.DB.prepare("DELETE FROM account_credit_operations").run();
  await env.DB.prepare("DELETE FROM account_devices").run();
  await env.DB.prepare("DELETE FROM account_sessions").run();
  await env.DB.prepare("DELETE FROM accounts").run();
  await env.DB.prepare(
    "UPDATE app_config SET value = 'off' WHERE key = 'accounts_enabled'",
  ).run();
});

describe("minimal account and credit ledger", () => {
  it("keeps purchases and revocations idempotent", async () => {
    const account = await env.DB.prepare(
      "INSERT INTO accounts (apple_subject_hash) VALUES ('subject') RETURNING id",
    ).first<{ id: number }>();
    await grantCreditPurchase(env.DB, account!.id, "tx-1", 30);
    await grantCreditPurchase(env.DB, account!.id, "tx-1", 30);
    expect(await creditBalance(env.DB, account!.id)).toBe(30);

    await revokeCreditPurchase(env.DB, "tx-1", 30);
    await revokeCreditPurchase(env.DB, "tx-1", 30);
    expect(await creditBalance(env.DB, account!.id)).toBe(0);
  });

  it("maps a signed-in device without storing its raw identifier", async () => {
    const account = await env.DB.prepare(
      "INSERT INTO accounts (apple_subject_hash) VALUES ('subject') RETURNING id",
    ).first<{ id: number }>();
    await env.DB.prepare(
      "INSERT INTO account_devices (device_hash, account_id) VALUES ('hash', ?)",
    ).bind(account!.id).run();
    expect(await accountForDevice(env.DB, "hash")).toBe(account!.id);
  });

  it("keeps login disabled and rejects malformed nonce input", async () => {
    expect((await handleAppleLogin(loginRequest("short"), env)).status).toBe(403);
    await env.DB.prepare(
      "UPDATE app_config SET value = 'on' WHERE key = 'accounts_enabled'",
    ).run();
    expect((await handleAppleLogin(loginRequest("short"), env)).status).toBe(400);
  });

  it("deletes account state through an authenticated session", async () => {
    const account = await env.DB.prepare(
      "INSERT INTO accounts (apple_subject_hash) VALUES ('subject') RETURNING id",
    ).first<{ id: number }>();
    const token = "s".repeat(43);
    await env.DB.prepare(`
      INSERT INTO account_sessions (token_hash, account_id, expires_at_ms)
      VALUES (?, ?, ?)
    `).bind(await hash(token), account!.id, Date.now() + 60_000).run();
    const response = await handleAccount(new Request("https://test/v1/account", {
      method: "DELETE",
      headers: {
        authorization: "Bearer test-token",
        "x-focelle-session": token,
      },
    }), env);
    expect(response.status).toBe(200);
    expect((await env.DB.prepare("SELECT COUNT(*) AS count FROM accounts")
      .first<{ count: number }>())?.count).toBe(0);
  });
});

function loginRequest(nonce: string): Request {
  return new Request("https://test/v1/account/apple", {
    method: "POST",
    headers: {
      authorization: "Bearer test-token",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      deviceId: "device_1234567890",
      identityToken: "invalid",
      nonce,
    }),
  });
}

async function hash(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
