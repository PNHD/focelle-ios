# Focelle

Focelle is an iPhone-first **AI photo coach** for photography beginners. The product is designed to improve composition, angle, exposure, and subject placement before the shutter is pressed, while keeping the camera usable even when cloud AI is unavailable.

## Product principles

- Open directly to the camera; no account required before shooting.
- Use on-device visual guidance first, concise text second, optional voice guidance third.
- Preserve natural faces and bodies; no face/body reshaping or plastic skin smoothing.
- Keep core camera controls and saving available without AI credits.
- Do not store user photos or AI prompt content in analytics.
- Prefer measurable camera/scene signals over generic photography advice.

## Current scope

- iPhone only, with iOS 18.1+ as the current minimum target.
- SwiftUI native application.
- Portrait, couple, and small-group composition guidance.
- On-device Vision/Core ML measurements with optional deeper cloud scene advice.
- Vietnamese-first product with English included.

The approved beta scope and constraints live in [`docs/focelle-spec.md`](docs/focelle-spec.md). Delivery planning lives in [`docs/focelle-plan.md`](docs/focelle-plan.md).

## Repository structure

- `Focelle/` — application source
- `FocelleTests/` — automated tests
- `Focelle.xcodeproj/` — Xcode project
- `docs/` — product specification and implementation plan
- `.github/` — CI workflows

## Development status

The project is under active development. The current milestone is a native iOS implementation with automated build/test coverage; product features are accepted only when they meet the documented beta constraints rather than from mock UI alone.
