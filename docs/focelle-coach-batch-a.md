# Focelle Coach Batch A — Locked Architecture

Status: **locked for FCL-M2 Build Batch A** (experimental, feature flag OFF by
default). This document describes the architecture as implemented; it is not
evidence that the feature works on a physical device.

## 1. Product contracts

### No automatic camera mutation

`PlanSession` (Focelle/Coach/PlanSession.swift) snapshots the zoom and
exposure baseline plus the capability generation at Analyze time. Analyze
only creates plans. Apply uses **absolute** zoom/exposure values from the
selected plan. Undo restores the exact pre-Analyze baseline. A camera switch
or capability-generation change invalidates the session (CameraSession clears
it in `configureCapabilities`). Repeated Apply/Undo cycles cannot compound or
drift.

### Feature flags

- `coachV2Enabled` — persisted, default **OFF**. When OFF, the app follows
  the FCL-M1 heuristic/cloud path unchanged.
- `aestheticsEnabled` — persisted, default **false**. No production effect in
  Batch A; the planner weight is zero and only the `VisionAestheticsScoring`
  protocol exists (section 6).

## 2. SceneDescriptor

`SceneDescriptor` (Focelle/Coach/SceneDescriptor.swift) is emitted by
`OnDeviceAnalyzer` on the analysis queue:

- selected subject identity ID and rect; human rects;
- normalized 2D body-pose landmarks with confidence;
- availability-gated 3D pose (`VNDetectHumanBodyPose3DRequest`), at most
  ~1 Hz, failing silently to nil on unsupported devices;
- face landmarks and face capture quality;
- saliency rect, horizon angle, luma;
- 8-bucket luma histogram, backlight indicator, contrast;
- blur/sharpness proxy (1 − normalized micro-contrast);
- cached low-cadence classifications (~2 s), derived from lighting and coarse
  scene structure only;
- generation and timestamp metadata.

Reuses the existing thermal throttling (0.7 s / 1.4 s full-detection cadence)
and stale-generation rejection (`SceneDescriptor.isCurrent`). Feature prints
are computed only for a selected subject, never per frame. No image bytes,
faces, landmarks, or reconstructable scene data are retained or logged.

## 3. Stabilization and selected-subject identity

`SubjectIdentityTracker` adopts a subject only on box-overlap (IoU ≥ 0.35) or
feature-print cosine evidence (≥ 0.92); after temporary tracking loss it
preserves the previous subject for 0.8 s, then reports the subject lost. It
never jumps to an unrelated salient object. `DescriptorStabilizer` applies a
deterministic EMA (0.5) to luma, face quality, lighting contrast, blur and
subject bounds.

## 4. Pose-template system

- Schema: versioned (`schemaVersion: 1`), stable IDs, category, framing,
  orientation, subject count, camera hints, named normalized landmarks,
  target framing, headroom, face zone, absolute recommended zoom, context
  tags, lighting constraints, Vietnamese/English instructions,
  `source: owned-synthetic`.
- Production: `scripts/generate_pose_templates.py` holds 14 manually reviewed
  canonical seeds and deterministically produces ~92 validated, deduplicated
  variants via mirroring, framing scale, camera height, lean, and
  multi-subject spacing. Regenerate with
  `python scripts/generate_pose_templates.py`; output is byte-deterministic
  (verified by running twice and comparing hashes).
- Validation: joint-angle bounds, limb-ratio plausibility, face zone inside
  frame with crop safety margin, ground placement, schema checks — mirrored
  in Swift (`PoseTemplateValidation`) so the checked-in bundle is validated
  by unit tests.
- Dedup: canonical rounding + mirror equivalence + distance threshold
  (`PoseTemplateDedup`).
- Bundle: `Focelle/Coach/PoseTemplates.json` checked into the app, loaded by
  `PoseTemplateStore`.

## 5. Deterministic local planner

`LocalPlanner` (Focelle/Coach/LocalPlanner.swift):

`SceneDescriptor + selected subject + framing intent → candidate retrieval →
hard rejection → scoring → diversity selection`.

- Hard rejection (runs before scoring): invalid template; crop cuts the face
  beyond the face zone; pose confidence too low for person categories;
  selected-subject identity mismatch; zoom beyond capability; subject-count
  incompatibility; target framing outside the active frame.
- Ranking features (tunable defaults, not claimed optimal): pose alignment
  0.25, framing fit 0.20, camera motion 0.15, context match 0.15, face quality
  0.10, lighting feasibility 0.10, intent fit 0.05. Experimental weights
  (aesthetics, affinity, embedding) are 0.
- Diversity: Primary = top score; Safe = least camera motion; Creative =
  greedy max-min distance from Primary and Safe with a distinct template.
- Everything works offline.

## 6. Vision aesthetics boundary (Batch A)

Benchmark first. Only the `VisionAestheticsScoring` protocol exists; the
concrete adapter is deferred to a later batch. `aestheticsEnabled` remains
false and the planner weight is zero. No claim of objective beauty.

## 7. Beta/internal integration

Settings exposes "AI Coach V2 (Experimental)" (default OFF). When enabled,
the Analyze button runs the local planner; the panel shows the three plan
titles, selection, Apply, and Undo. Apply/Undo use `PlanSession`. The selected
plan's target frame renders through the existing `GuidanceOverlay` (target
frame is now also drawn for `.none` directions). Disabling the flag returns
immediately to the FCL-M1 heuristic/cloud path. No Batch B UI (final plan
cards, intent chips, cloud schema v3, skeleton animation).

## 8. Boundaries and evidence

- No Build Batch B, no cloud schema v3, no model download, no custom
  training, no MediaPipe/MobileCLIP/NIMA/Apple Foundation Models image input.
- This batch does not claim improved photographs, thermal pass, cloud AI
  success, or production readiness. Highest evidence at commit time:
  `AUTOMATED TESTED` (unit tests) + deterministic generator re-run; macOS CI
  and physical iPhone validation are separate gates.
