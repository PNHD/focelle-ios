import { env as testEnv } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";
import { handleAnalyze, stripJpegMetadata, type Fetcher } from "../src/analyze";

const validResult = {
  schemaVersion: 1,
  primary: plan("primary"),
  alternatives: [plan("safe"), plan("creative")],
};

describe("analyze", () => {
  it("rejects missing authentication", async () => {
    const response = await handleAnalyze(request(), environment(), provider(validResult));
    expect(response.status).toBe(401);
  });

  it("rejects oversized images", async () => {
    const response = await handleAnalyze(
      request("A".repeat(1_300_000), true),
      environment(),
      provider(validResult),
    );
    expect(response.status).toBe(413);
  });

  it("maps provider timeout", async () => {
    const timeout: Fetcher = vi.fn(async () => {
      throw new DOMException("timed out", "TimeoutError");
    });
    const response = await handleAnalyze(request(jpeg(), true), environment(), timeout);
    expect(await response.json()).toEqual({
      ok: false,
      error: { code: "PROVIDER_TIMEOUT" },
    });
  });

  it("rejects malformed structured output", async () => {
    const response = await handleAnalyze(
      request(jpeg(), true),
      environment(),
      provider({ schemaVersion: 1 }),
    );
    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({
      ok: false,
      error: { code: "INVALID_AI_RESPONSE" },
    });
  });

  it("rejects a target rectangle outside the preview", async () => {
    const result = structuredClone(validResult);
    result.primary.target = { x: 0.9, y: 0.5, width: 0.3, height: 0.5 };
    const response = await handleAnalyze(
      request(jpeg(), true),
      environment(),
      provider(result),
    );
    expect(response.status).toBe(502);
  });

  it("maps provider rate limits", async () => {
    const response = await handleAnalyze(
      request(jpeg(), true),
      environment(),
      vi.fn(async () => new Response(null, { status: 429 })),
    );
    expect(await response.json()).toEqual({
      ok: false,
      error: { code: "PROVIDER_RATE_LIMITED" },
    });
  });

  it("rejects invalid JPEG data without reaching the provider", async () => {
    const fetcher = provider(validResult);
    const response = await handleAnalyze(
      request(btoa("not a jpeg"), true),
      environment(),
      fetcher,
    );
    expect(response.status).toBe(400);
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("returns one primary and two alternatives", async () => {
    const response = await handleAnalyze(
      request(jpeg(), true),
      environment(),
      provider(validResult),
    );
    expect(response.status).toBe(200);
    expect((await response.json() as { result: typeof validResult }).result).toEqual(validResult);
  });

  it("maps app rate limits without KV", async () => {
    const response = await handleAnalyze(
      request(jpeg(), true),
      environment(false),
      provider(validResult),
    );
    expect(response.status).toBe(429);
  });
});

describe("JPEG privacy", () => {
  it("removes EXIF application segments before forwarding", () => {
    const image = Uint8Array.from([
      0xff, 0xd8,
      0xff, 0xe1, 0x00, 0x04, 0x45, 0x58,
      0xff, 0xdb, 0x00, 0x04, 0x00, 0x01,
      0xff, 0xda, 0x00, 0x02, 0x12, 0x34, 0xff, 0xd9,
    ]);
    expect([...stripJpegMetadata(image)]).toEqual([
      0xff, 0xd8,
      0xff, 0xdb, 0x00, 0x04, 0x00, 0x01,
      0xff, 0xda, 0x00, 0x02, 0x12, 0x34, 0xff, 0xd9,
    ]);
  });
});

function request(image = jpeg(), authenticated = false): Request {
  return new Request("https://example.test/v1/analyze", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(authenticated ? { authorization: "Bearer test-token" } : {}),
    },
    body: JSON.stringify({
      deviceId: "device_1234567890",
      requestId: "request_1234567890123456",
      timezoneOffsetMinutes: 420,
      locale: "vi",
      image: { mimeType: "image/jpeg", data: image },
    }),
  });
}

function environment(rateAllowed = true): Env {
  return {
    APP_SHARED_TOKEN: "test-token",
    GEMINI_API_KEY: "test-key",
    GEMINI_MODEL: "gemini-3.5-flash-lite",
    DB: testEnv.DB,
    AI_RATE_LIMITER: {
      limit: vi.fn(async () => ({ success: rateAllowed })),
    },
    EVENT_RATE_LIMITER: {
      limit: vi.fn(async () => ({ success: true })),
    },
  };
}

function provider(result: unknown): Fetcher {
  return vi.fn(async () => Response.json({
    candidates: [{
      content: { parts: [{ text: JSON.stringify(result) }] },
    }],
  }));
}

function plan(id: "primary" | "safe" | "creative") {
  return {
    id,
    instructionVi: "Dich may sang trai",
    instructionEn: "Move camera left",
    target: { x: 0.33, y: 0.5, width: 0.3, height: 0.5 },
    movement: "left",
    angle: "eye-level",
    zoom: 1.2,
    exposureBias: 0,
    flash: "off",
    presetIDs: ["neutral-skin"],
    poseVi: "Xoay vai nhe",
    poseEn: "Turn shoulders slightly",
  };
}

function jpeg(): string {
  return btoa(String.fromCharCode(
    0xff, 0xd8,
    0xff, 0xdb, 0x00, 0x04, 0x00, 0x01,
    0xff, 0xda, 0x00, 0x02, 0x12, 0x34, 0xff, 0xd9,
  ));
}
