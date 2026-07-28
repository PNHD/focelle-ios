export const movements = [
  "none",
  "left",
  "right",
  "up",
  "down",
  "closer",
  "farther",
  "level",
] as const;

export const flashes = ["off", "auto", "on"] as const;

export const presetIDs = [
  "neutral-skin",
  "clean-bright",
  "soft-portrait",
  "warm-glow",
  "golden-hour",
  "cafe-amber",
  "travel-vivid",
  "cool-air",
  "night-neon",
  "faded-film",
  "matte-grain",
  "mono-contrast",
] as const;

// Version 2 carries one instruction and one pose, written in the locale the client
// asked for. Version 1 hard-coded instructionVi/instructionEn, so every added
// language cost the model three more strings per request.
export type CompositionPlan = {
  id: "primary" | "safe" | "creative";
  instruction: string;
  target: { x: number; y: number; width: number; height: number };
  movement: (typeof movements)[number];
  angle: "eye-level" | "slightly-high" | "slightly-low";
  zoom: number;
  exposureBias: number;
  flash: (typeof flashes)[number];
  presetIDs: (typeof presetIDs)[number][];
  pose: string;
};

export type CompositionResponse = {
  schemaVersion: 2;
  primary: CompositionPlan;
  alternatives: [CompositionPlan, CompositionPlan];
};

const planSchema = {
  type: "object",
  additionalProperties: false,
  required: [
    "id",
    "instruction",
    "target",
    "movement",
    "angle",
    "zoom",
    "exposureBias",
    "flash",
    "presetIDs",
    "pose",
  ],
  properties: {
    id: { type: "string", enum: ["primary", "safe", "creative"] },
    instruction: { type: "string" },
    target: {
      type: "object",
      additionalProperties: false,
      required: ["x", "y", "width", "height"],
      properties: {
        x: { type: "number", minimum: 0, maximum: 1 },
        y: { type: "number", minimum: 0, maximum: 1 },
        width: { type: "number", minimum: 0.01, maximum: 1 },
        height: { type: "number", minimum: 0.01, maximum: 1 },
      },
    },
    movement: { type: "string", enum: movements },
    angle: {
      type: "string",
      enum: ["eye-level", "slightly-high", "slightly-low"],
    },
    zoom: { type: "number", minimum: 1, maximum: 5 },
    exposureBias: { type: "number", minimum: -2, maximum: 2 },
    flash: { type: "string", enum: flashes },
    presetIDs: {
      type: "array",
      minItems: 1,
      maxItems: 3,
      items: { type: "string", enum: presetIDs },
    },
    pose: { type: "string" },
  },
} as const;

export const compositionResponseSchema = {
  type: "object",
  additionalProperties: false,
  required: ["schemaVersion", "primary", "alternatives"],
  properties: {
    schemaVersion: { type: "integer", enum: [2] },
    primary: planSchema,
    alternatives: {
      type: "array",
      minItems: 2,
      maxItems: 2,
      items: planSchema,
    },
  },
} as const;

export function isCompositionResponse(value: unknown): value is CompositionResponse {
  if (!isExactObject(value, ["schemaVersion", "primary", "alternatives"])) return false;
  if (value.schemaVersion !== 2 || !Array.isArray(value.alternatives)) return false;
  if (value.alternatives.length !== 2 || !isPlan(value.primary)) return false;
  return value.alternatives.every(isPlan)
    && value.primary.id === "primary"
    && value.alternatives[0]?.id === "safe"
    && value.alternatives[1]?.id === "creative";
}

function isPlan(value: unknown): value is CompositionPlan {
  if (!isExactObject(value, [
    "id", "instruction", "target", "movement", "angle",
    "zoom", "exposureBias", "flash", "presetIDs", "pose",
  ])) return false;
  if (!["primary", "safe", "creative"].includes(String(value.id))) return false;
  if (!shortText(value.instruction, 120) || !shortText(value.pose, 160)) return false;
  if (!movements.includes(value.movement as (typeof movements)[number])) return false;
  if (!["eye-level", "slightly-high", "slightly-low"].includes(String(value.angle))) return false;
  if (!flashes.includes(value.flash as (typeof flashes)[number])) return false;
  if (!numberIn(value.zoom, 1, 5) || !numberIn(value.exposureBias, -2, 2)) return false;
  if (!Array.isArray(value.presetIDs) || value.presetIDs.length < 1 || value.presetIDs.length > 3) return false;
  if (!value.presetIDs.every((id) => presetIDs.includes(id as (typeof presetIDs)[number]))) return false;
  return isRect(value.target);
}

function isRect(value: unknown): boolean {
  return isExactObject(value, ["x", "y", "width", "height"])
    && numberIn(value.x, 0, 1)
    && numberIn(value.y, 0, 1)
    && numberIn(value.width, 0.01, 1)
    && numberIn(value.height, 0.01, 1)
    && value.x + value.width <= 1
    && value.y + value.height <= 1;
}

function isExactObject(
  value: unknown,
  keys: readonly string[],
): value is Record<string, unknown> {
  return typeof value === "object"
    && value !== null
    && !Array.isArray(value)
    && Object.keys(value).length === keys.length
    && keys.every((key) => Object.hasOwn(value, key));
}

function shortText(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

function numberIn(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= min && value <= max;
}
