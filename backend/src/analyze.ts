import {
  compositionResponseSchema,
  isCompositionResponse,
  type CompositionResponse,
} from "./schema";
import { recordSuccessfulAnalysis } from "./beta";
import { authorized, error, json, PayloadTooLarge, readJSON } from "./http";

const MAX_REQUEST_BYTES = 1_500_000;
const MAX_IMAGE_BYTES = 900_000;
const MAX_PROVIDER_BYTES = 256_000;

type AnalyzeRequest = {
  deviceId: string;
  locale: "vi" | "en";
  image: { mimeType: "image/jpeg"; data: string };
  measurements?: {
    subject?: { x: number; y: number; width: number; height: number };
    faces: number;
    horizonAngle?: number;
    exposure: number;
  };
};

type Fetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export async function handleAnalyze(
  request: Request,
  env: Env,
  fetcher: Fetcher = fetch,
  context?: ExecutionContext,
): Promise<Response> {
  if (request.method !== "POST") return error("METHOD_NOT_ALLOWED", 405);
  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    return error("BAD_REQUEST", 400);
  }
  if (!await authorized(request, env.APP_SHARED_TOKEN)) return error("AUTH_REQUIRED", 401);

  let input: AnalyzeRequest;
  try {
    input = validateRequest(await readJSON(request, MAX_REQUEST_BYTES));
  } catch (cause) {
    return cause instanceof PayloadTooLarge
      ? error("PAYLOAD_TOO_LARGE", 413)
      : error("BAD_REQUEST", 400);
  }

  const rate = await env.AI_RATE_LIMITER.limit({ key: input.deviceId });
  if (!rate.success) return error("RATE_LIMITED", 429);

  let strippedImage: Uint8Array;
  try {
    strippedImage = stripJpegMetadata(decodeBase64(input.image.data));
  } catch {
    return error("BAD_REQUEST", 400);
  }
  const providerRequest = {
    contents: [{
      role: "user",
      parts: [
        {
          text: [
            "You are Focelle, a practical photo composition coach.",
            "Analyze only composition, camera position, framing, light, and simple pose.",
            "Do not identify people or infer sensitive attributes.",
            "Return one primary, one safe, and one creative plan.",
            `Locale preference: ${input.locale}.`,
            `On-device measurements: ${JSON.stringify(input.measurements ?? {})}`,
          ].join("\n"),
        },
        {
          inlineData: {
            mimeType: "image/jpeg",
            data: encodeBase64(strippedImage),
          },
        },
      ],
    }],
    generationConfig: {
      responseMimeType: "application/json",
      responseJsonSchema: compositionResponseSchema,
      temperature: 0.25,
      maxOutputTokens: 1_500,
    },
  };

  let provider: Response;
  try {
    provider = await fetcher(
      `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(env.GEMINI_MODEL)}:generateContent`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-goog-api-key": env.GEMINI_API_KEY,
        },
        body: JSON.stringify(providerRequest),
        signal: AbortSignal.timeout(9_500),
      },
    );
  } catch (cause) {
    return cause instanceof DOMException && cause.name === "TimeoutError"
      ? error("PROVIDER_TIMEOUT", 504)
      : error("PROVIDER_ERROR", 502);
  }

  if (provider.status === 429) return error("PROVIDER_RATE_LIMITED", 503);
  if (!provider.ok) return error("PROVIDER_ERROR", 502);

  try {
    const body = await readJSON(provider, MAX_PROVIDER_BYTES);
    const text = providerText(body);
    const result: unknown = JSON.parse(text);
    if (!isCompositionResponse(result)) return error("INVALID_AI_RESPONSE", 502);
    context?.waitUntil(recordSuccessfulAnalysis(env.DB, input.deviceId));
    return json({ ok: true, result });
  } catch {
    return error("INVALID_AI_RESPONSE", 502);
  }
}

function validateRequest(value: unknown): AnalyzeRequest {
  if (!isExactObject(value, ["deviceId", "locale", "image"], ["measurements"])) {
    throw new Error("invalid");
  }
  if (!isExactObject(value.image, ["mimeType", "data"])) throw new Error("invalid");
  if (typeof value.deviceId !== "string" || !/^[A-Za-z0-9_-]{16,64}$/.test(value.deviceId)) {
    throw new Error("invalid");
  }
  if (value.locale !== "vi" && value.locale !== "en") throw new Error("invalid");
  if (value.image.mimeType !== "image/jpeg" || typeof value.image.data !== "string") {
    throw new Error("invalid");
  }
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(value.image.data)) throw new Error("invalid");
  if (Math.floor(value.image.data.length * 0.75) > MAX_IMAGE_BYTES) {
    throw new PayloadTooLarge();
  }
  const measurements = validateMeasurements(value.measurements);
  return {
    deviceId: value.deviceId,
    locale: value.locale,
    image: { mimeType: "image/jpeg", data: value.image.data },
    ...(measurements ? { measurements } : {}),
  };
}

function validateMeasurements(value: unknown): AnalyzeRequest["measurements"] {
  if (value === undefined) return undefined;
  if (!isExactObject(value, ["faces", "exposure"], ["subject", "horizonAngle"])) {
    throw new Error("invalid");
  }
  if (!Number.isInteger(value.faces) || !numberIn(value.faces, 0, 20)) throw new Error("invalid");
  if (!numberIn(value.exposure, 0, 1)) throw new Error("invalid");
  if (value.horizonAngle !== undefined && !numberIn(value.horizonAngle, -Math.PI, Math.PI)) {
    throw new Error("invalid");
  }
  const subject = value.subject === undefined ? undefined : validateRect(value.subject);
  return {
    faces: value.faces,
    exposure: value.exposure,
    ...(subject ? { subject } : {}),
    ...(typeof value.horizonAngle === "number" ? { horizonAngle: value.horizonAngle } : {}),
  };
}

function validateRect(value: unknown): { x: number; y: number; width: number; height: number } {
  if (!isExactObject(value, ["x", "y", "width", "height"])) throw new Error("invalid");
  if (!numberIn(value.x, 0, 1)
    || !numberIn(value.y, 0, 1)
    || !numberIn(value.width, 0, 1)
    || !numberIn(value.height, 0, 1)) throw new Error("invalid");
  return { x: value.x, y: value.y, width: value.width, height: value.height };
}

function providerText(value: unknown): string {
  if (!isObject(value) || !Array.isArray(value.candidates)) throw new Error("invalid");
  const candidate = value.candidates[0];
  if (!isObject(candidate) || !isObject(candidate.content) || !Array.isArray(candidate.content.parts)) {
    throw new Error("invalid");
  }
  const part = candidate.content.parts.find(
    (item) => isObject(item) && typeof item.text === "string",
  );
  if (!isObject(part) || typeof part.text !== "string") throw new Error("invalid");
  return part.text;
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function encodeBase64(value: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < value.length; offset += 0x8000) {
    binary += String.fromCharCode(...value.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

export function stripJpegMetadata(input: Uint8Array): Uint8Array {
  if (input.length < 4 || input[0] !== 0xff || input[1] !== 0xd8) {
    throw new Error("invalid jpeg");
  }
  const output: Uint8Array[] = [Uint8Array.of(0xff, 0xd8)];
  let offset = 2;
  while (offset + 1 < input.length) {
    if (input[offset] !== 0xff) throw new Error("invalid jpeg");
    const marker = input.at(offset + 1);
    if (marker === undefined) throw new Error("invalid jpeg");
    if (marker === 0xda) {
      output.push(input.subarray(offset));
      return concatenate(output);
    }
    if (marker === 0xd9) {
      output.push(Uint8Array.of(0xff, 0xd9));
      return concatenate(output);
    }
    if (offset + 3 >= input.length) throw new Error("invalid jpeg");
    const high = input.at(offset + 2);
    const low = input.at(offset + 3);
    if (high === undefined || low === undefined) throw new Error("invalid jpeg");
    const length = (high << 8) | low;
    if (length < 2 || offset + length + 2 > input.length) throw new Error("invalid jpeg");
    const isMetadata = (marker >= 0xe1 && marker <= 0xef) || marker === 0xfe;
    if (!isMetadata) output.push(input.subarray(offset, offset + length + 2));
    offset += length + 2;
  }
  throw new Error("invalid jpeg");
}

function concatenate(chunks: Uint8Array[]): Uint8Array {
  const output = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.length;
  }
  return output;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isExactObject(
  value: unknown,
  required: readonly string[],
  optional: readonly string[] = [],
): value is Record<string, unknown> {
  if (!isObject(value)) return false;
  const allowed = new Set([...required, ...optional]);
  return required.every((key) => Object.hasOwn(value, key))
    && Object.keys(value).every((key) => allowed.has(key));
}

function numberIn(value: unknown, minimum: number, maximum: number): value is number {
  return typeof value === "number"
    && Number.isFinite(value)
    && value >= minimum
    && value <= maximum;
}

export type { AnalyzeRequest, CompositionResponse, Fetcher };
