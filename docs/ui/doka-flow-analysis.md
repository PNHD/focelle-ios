# Doka Cam tutorial analysis

Source: user-provided `DOKA CAM APP - HOW TO USE [n5qtMGypWyw] [1080p].mp4`.

Analyzed on 2026-07-26. The 03:03.623 recording contains 5,507 frames at 30 fps,
394x854. The review used a full 1 fps timeline plus 2-5 fps passes around every
interaction. Extracted frames are temporary review material and are not included
in this repository.

## Confirmed flow

| Time | Doka behavior | Focelle decision |
| --- | --- | --- |
| 00:00-00:36 | App Store install, product copy, screenshots, ratings | No product behavior to copy. |
| 00:36-00:40 | Splash, then a privacy agreement before camera access | Keep Focelle's privacy explanation, but request system permissions only when entering the camera. |
| 00:40-00:48 | Five usage-tip screens: activate AI Compose, keep still, aim at a colored ring, align with a colored frame for lens adjustment, then tap shutter after composition locks | Use the interaction model, not Doka's assets or wording. |
| 00:48-00:53 | Camera permission followed by Photos permission | Keep just-in-time permission requests and useful denied states. |
| 00:53-01:00 | Camera opens with discrete lens choices, manual shutter and a separate AI Compose action | Keep capture usable without cloud AI. |
| 01:00-01:09 | Album photo opens; adjustment tools use one active slider over a large preview | Focelle already supports live preview and adjustable presets; retain a non-destructive original. |
| 01:09-01:23 | Filter browser uses categories, horizontal cards and a 0-100 intensity slider | Keep categories/favorites/presets and show intensity continuously. Do not add a watermark. |
| 01:23-01:25 | Export offers border styles, including Doka branding | Skip branded output by default. |
| 01:25-01:57 | Live camera filter preview; user switches categories and presets without leaving capture | Keep real-time Core Image preview and user-created presets. |
| 01:49-01:52 | A filter detail page explains a preset's visual intent and tags | Add descriptions only when the preset catalog is large enough to need discovery. |
| 01:57-02:00 | A compact camera menu exposes flash, tap shutter, grid, level, composition/filter coupling, multi-view and subject selection | Keep advanced controls available without crowding the shutter. |
| 02:06-02:23 | First AI Compose use shows three timed tips: static scenes only; require a clear subject; keep still and do not zoom during analysis | Focelle now makes the steady requirement explicit. Avoid Doka's forced five-second wait. |
| 02:23-02:28 | Returns to camera; this recording does not show a successful live AI composition | Do not infer latency, tracking quality or auto-capture reliability from this video. |
| 02:28-02:47 | Settings expose subject selection, personalized AI filters, composition plus filter, multi-view, grid, flash, tap shutter, level, output originals, watermark/border, app icon and language | Preserve the useful controls already in Focelle; keep privacy and output choices explicit. |
| 02:47-03:03 | Share sheet, App Store search, exit | No camera behavior to apply. |

## Guidance state machine

The tutorial proves five distinct states. They should not be represented by one
ambiguous arrow:

1. **Find subject** — show a subject affordance; no target ring yet.
2. **Analyzing** — freeze the sampled cloud-AI frame and tell the user to hold
   steady. Local Vision tracking may continue.
3. **Move in two dimensions** — current subject-center dot, connecting path and
   colored target ring.
4. **Adjust scale/lens** — current subject box plus a colored target frame.
5. **Locked** — green state, success haptic, shutter remains available; optional
   Focelle auto-capture waits for stable alignment and face readiness.

Focelle improves the Doka flow by leaving the native camera and on-device
guidance usable while cloud AI is unavailable, avoiding forced tutorial
countdowns, and making auto-capture optional instead of hiding manual capture.

## What the recording does not prove

- No successful live AI Compose sequence is recorded.
- No evidence establishes the AI model/provider, server architecture or exact
  analysis latency.
- The tutorial illustrations do not prove that every overlay tracks at 30 fps.
- The recording does not demonstrate moving-subject support; its own tips say
  the feature is intended for static scenes.

These unknowns require physical-device testing with people, food, landscapes,
low light and motion. They must not be replaced by assumptions from marketing
screens.
