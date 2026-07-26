import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { creditBalance } from "../src/account";
import {
  handleReferral,
  hasActiveReferral,
  qualifyReferral,
  reverseReferral,
} from "../src/referral";

beforeEach(async () => {
  await env.DB.prepare("DELETE FROM referral_claims").run();
  await env.DB.prepare("DELETE FROM referral_codes").run();
  await env.DB.prepare("DELETE FROM account_credit_operations").run();
  await env.DB.prepare("DELETE FROM account_devices").run();
  await env.DB.prepare("DELETE FROM account_sessions").run();
  await env.DB.prepare("DELETE FROM accounts").run();
  await env.DB.prepare(
    "UPDATE app_config SET value = 'on' WHERE key = 'referral_enabled'",
  ).run();
});

describe("verified-purchase referrals", () => {
  it("blocks self/repeat claims, rewards once, and reverses refunds", async () => {
    const referrer = await makeAccount("referrer", "r".repeat(43), "hash-r");
    const referred = await makeAccount("referred", "u".repeat(43), "hash-u");
    const codeResponse = await handleReferral(request("GET", "r".repeat(43)), env);
    const code = (await codeResponse.json() as {
      referral: { code: string };
    }).referral.code;

    expect((await handleReferral(request("POST", "r".repeat(43), code), env)).status)
      .toBe(409);
    expect((await handleReferral(request("POST", "u".repeat(43), code), env)).status)
      .toBe(200);
    expect((await handleReferral(request("POST", "u".repeat(43), code), env)).status)
      .toBe(409);

    const now = new Date("2026-07-26T12:00:00Z");
    await Promise.all([
      qualifyReferral(env.DB, referred, "tx-1", now),
      qualifyReferral(env.DB, referred, "tx-2", now),
    ]);
    expect(await creditBalance(env.DB, referrer)).toBe(30);
    expect(await hasActiveReferral(env.DB, "hash-u", now)).toBe(true);

    const qualified = await env.DB.prepare(`
      SELECT qualified_transaction_id FROM referral_claims
      WHERE referred_account_id = ?
    `).bind(referred).first<{ qualified_transaction_id: string }>();
    await reverseReferral(env.DB, qualified!.qualified_transaction_id);
    await reverseReferral(env.DB, qualified!.qualified_transaction_id);
    expect(await creditBalance(env.DB, referrer)).toBe(0);
    expect(await hasActiveReferral(env.DB, "hash-u", now)).toBe(false);
  });

  it("rejects expired referral codes", async () => {
    await makeAccount("referrer", "r".repeat(43), "hash-r");
    await makeAccount("referred", "u".repeat(43), "hash-u");
    const response = await handleReferral(request("GET", "r".repeat(43)), env);
    const code = (await response.json() as { referral: { code: string } }).referral.code;
    await env.DB.prepare(
      "UPDATE referral_codes SET created_at = datetime('now', '-91 days')",
    ).run();
    expect((await handleReferral(request("POST", "u".repeat(43), code), env)).status)
      .toBe(404);
  });
});

async function makeAccount(subject: string, token: string, deviceHash: string): Promise<number> {
  const account = await env.DB.prepare(
    "INSERT INTO accounts (apple_subject_hash) VALUES (?) RETURNING id",
  ).bind(subject).first<{ id: number }>();
  await env.DB.batch([
    env.DB.prepare(`
      INSERT INTO account_sessions (token_hash, account_id, expires_at_ms)
      VALUES (?, ?, ?)
    `).bind(await hash(token), account!.id, Date.now() + 60_000),
    env.DB.prepare(
      "INSERT INTO account_devices (device_hash, account_id) VALUES (?, ?)",
    ).bind(deviceHash, account!.id),
  ]);
  return account!.id;
}

function request(method: string, token: string, code?: string): Request {
  return new Request("https://test/v1/referral", {
    method,
    headers: {
      authorization: "Bearer test-token",
      "x-focelle-session": token,
      "content-type": "application/json",
    },
    ...(code ? { body: JSON.stringify({ code }) } : {}),
  });
}

async function hash(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
