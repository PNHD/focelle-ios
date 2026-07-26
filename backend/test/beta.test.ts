import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  betaStatus,
  handleEvent,
  recordSuccessfulAnalysis,
} from "../src/beta";

const deviceId = "device_1234567890";

beforeEach(async () => {
  await env.DB.prepare("DELETE FROM events").run();
  await env.DB.prepare("DELETE FROM beta_devices").run();
  await env.DB.prepare(
    "UPDATE app_config SET value = 'auto' WHERE key = 'beta_force'",
  ).run();
});

describe("beta access", () => {
  it("activates exactly once after three successful analyses", async () => {
    await recordSuccessfulAnalysis(env.DB, deviceId);
    await recordSuccessfulAnalysis(env.DB, deviceId);
    expect((await betaStatus(env.DB, deviceId)).activated).toBe(false);

    await recordSuccessfulAnalysis(env.DB, deviceId);
    await recordSuccessfulAnalysis(env.DB, deviceId);
    const status = await betaStatus(env.DB, deviceId);
    expect(status.activated).toBe(true);
    expect(status.successfulAnalyses).toBe(3);
    expect(status.activatedUsers).toBe(1);
  });

  it("obeys the remote off switch", async () => {
    await env.DB.prepare(
      "UPDATE app_config SET value = 'off' WHERE key = 'beta_force'",
    ).run();
    expect((await betaStatus(env.DB, deviceId)).enabled).toBe(false);
  });
});

describe("anonymous events", () => {
  it("stores only allowlisted event names and a hashed device id", async () => {
    const response = await handleEvent(eventRequest("ai_success"), env);
    expect(response.status).toBe(202);
    const row = await env.DB.prepare(
      "SELECT device_hash, name FROM events",
    ).first<{ device_hash: string; name: string }>();
    expect(row?.device_hash).not.toContain(deviceId);
    expect(row?.name).toBe("ai_success");
  });

  it("rejects extra fields and unapproved event names", async () => {
    expect((await handleEvent(eventRequest("photo_uploaded"), env)).status).toBe(400);
    expect((await handleEvent(new Request("https://test/v1/events", {
      method: "POST",
      headers: {
        authorization: "Bearer test-token",
        "content-type": "application/json",
      },
      body: JSON.stringify({ deviceId, name: "ai_success", photo: "data" }),
    }), env)).status).toBe(400);
  });
});

function eventRequest(name: string): Request {
  return new Request("https://test/v1/events", {
    method: "POST",
    headers: {
      authorization: "Bearer test-token",
      "content-type": "application/json",
    },
    body: JSON.stringify({ deviceId, name }),
  });
}
