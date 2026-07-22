# Implementation Plan: Focelle iOS Beta

## Status

Draft for user review. Based on the approved `docs/focelle-spec.md`. No implementation begins until this plan is approved.

## Delivery Strategy

Build the smallest complete camera path first, prove it on macOS CI and the iPhone 17e, then add one vertical feature slice at a time. Native Apple frameworks remain the default; new dependencies require a demonstrated gap.

```text
macOS CI project
  -> camera capture/save
    -> owned filter pipeline
      -> on-device guidance
        -> cloud AI tap
          -> iCloud presets/editor
            -> beta controls/analytics
              -> StoreKit/ads/referral
                -> device hardening/TestFlight
```

## Architecture Decisions

- Native SwiftUI + AVFoundation, not React Native, because the core product depends on Apple camera, Vision, Core Image, iCloud, StoreKit, and future Foundation Models APIs.
- One app target and one test target initially. Split only when build/test pressure requires it.
- Concrete feature types first; no generic service/factory layers with one implementation.
- Vision/Core ML owns continuous geometry. Gemini owns one-tap semantic advice. The camera never waits on Gemini to remain usable.
- Core Image parameter recipes are the source of truth for Focelle Originals. Generate/use color cubes only where measured rendering performance requires them.
- Local state is offline-first. iCloud syncs preset records; Cloudflare D1 is authoritative only for server-controlled beta, quota, entitlement, and referral data.
- StoreKit 2 remains the source of purchase truth. The backend verifies server-side events and synchronizes consumable balance after Sign in with Apple.
- GitHub Actions macOS runners are the initial build/test path. Add Codemagic only if signing/TestFlight automation materially fails.

## Phase 1: Prove the Build and Camera

### Task 1: Create the native project and macOS CI

**Description:** Create the minimal SwiftUI app/test targets, deterministic project settings, localization placeholders, and a GitHub Actions workflow that builds and tests without signing.

**Acceptance criteria:**
- [ ] The app launches to a placeholder camera screen on an iOS simulator.
- [ ] Debug build and one smoke test pass on a pinned macOS/Xcode runner.
- [ ] CI archives logs and a simulator screenshot artifact.

**Verification:**
- [ ] Run the spec's unsigned `xcodebuild ... build` command in CI.
- [ ] Run the spec's simulator `xcodebuild ... test` command in CI.
- [ ] Inspect the uploaded screenshot and build logs.

**Dependencies:** None.

**Files likely touched:** `Focelle.xcodeproj/project.pbxproj`, `Focelle/App/FocelleApp.swift`, `Focelle/App/CameraPlaceholderView.swift`, `FocelleTests/SmokeTests.swift`, `.github/workflows/ios.yml`.

**Estimated scope:** Medium (5 files).

### Task 2: Deliver a real camera capture path

**Description:** Replace the placeholder with an AVFoundation preview, permissions, front/rear switching, shutter, and save-to-Photos flow.

**Acceptance criteria:**
- [ ] Permission denial and recovery show clear, non-blocking states.
- [ ] Front/rear capture saves a correctly oriented unfiltered image to Photos.
- [ ] Camera and save failures leave the screen usable.

**Verification:**
- [ ] Unit-test permission/capture state transitions.
- [ ] CI build/test passes.
- [ ] Physical check on iPhone 17e: permissions, switching, capture, save, orientation.

**Dependencies:** Task 1.

**Files likely touched:** `Focelle/Camera/CameraView.swift`, `Focelle/Camera/CameraSession.swift`, `Focelle/Camera/CameraState.swift`, `Focelle/Camera/PhotoSaver.swift`, `FocelleTests/CameraStateTests.swift`.

**Estimated scope:** Medium (5 files).

### Task 3: Add essential native camera controls

**Description:** Add zoom, tap focus, exposure bias, flash choice, timer, grid, aspect ratio, volume shutter, and supported resolution selection without changing the capture architecture.

**Acceptance criteria:**
- [ ] Unsupported controls are hidden or safely downgraded per device.
- [ ] Default capture is 24 MP where available; 48 MP is opt-in.
- [ ] Portrait/landscape controls and output orientation agree.

**Verification:**
- [ ] Unit-test capability mapping and orientation transforms.
- [ ] Physical matrix on iPhone 17e for 4:3, 1:1, 16:9, zoom, focus, flash, timer, and 24/48 MP.

**Dependencies:** Task 2.

**Files likely touched:** `Focelle/Camera/CameraControlsView.swift`, `Focelle/Camera/CameraSession.swift`, `Focelle/Camera/CameraCapabilities.swift`, `Focelle/Camera/VolumeShutter.swift`, `FocelleTests/CameraCapabilitiesTests.swift`.

**Estimated scope:** Medium (5 files).

## Checkpoint A: Native Camera

- [ ] CI build/tests pass from the Windows-authored repository.
- [ ] iPhone 17e captures and saves correct front/rear, portrait/landscape images.
- [ ] Permission and hardware failure states keep the camera usable.
- [ ] User reviews a short screen recording before filter work begins.

## Phase 2: Owned Color Pipeline

### Task 4: Implement Focelle Originals rendering

**Description:** Implement the 12 approved original recipes with one Core Image renderer shared by live preview, full-resolution capture, and existing-photo export.

**Acceptance criteria:**
- [ ] All 12 looks render from owned numeric recipes with no third-party LUT assets.
- [ ] Preview and saved output are visually consistent in the correct color space.
- [ ] Rendering failure saves the original rather than losing the photo.

**Verification:**
- [ ] Snapshot/perceptual tests run on small owned synthetic/reference images.
- [ ] Physical comparison of preview vs saved HEIF/JPEG on iPhone 17e.

**Dependencies:** Task 2.

**Files likely touched:** `Focelle/Filters/FilterRecipe.swift`, `Focelle/Filters/FocelleOriginals.swift`, `Focelle/Filters/FilterRenderer.swift`, `Focelle/Camera/CameraView.swift`, `FocelleTests/FilterRendererTests.swift`.

**Estimated scope:** Medium (5 files).

### Task 5: Add the live filter and preset editor

**Description:** Add filter thumbnails, favorite selection, Tone x Color pad, Intensity slider, original comparison, reset, and advanced controls.

**Acceptance criteria:**
- [ ] Edits update the preview smoothly and preserve the base recipe.
- [ ] Reset and press-to-compare are reliable and accessible.
- [ ] Saving with a filter uses the visible settings; previewing never spends a credit.

**Verification:**
- [ ] Unit-test parameter clamping, reset, and serialized edits.
- [ ] Physical interaction/performance check on iPhone 17e.

**Dependencies:** Task 4.

**Files likely touched:** `Focelle/Filters/FilterPickerView.swift`, `Focelle/Filters/PresetEditorView.swift`, `Focelle/Filters/PresetDraft.swift`, `Focelle/Camera/CameraView.swift`, `FocelleTests/PresetDraftTests.swift`.

**Estimated scope:** Medium (5 files).

### Task 6: Save custom presets and sync through iCloud

**Description:** Store versioned custom preset records locally, merge them through private iCloud storage, and remain usable when iCloud is off or unavailable.

**Acceptance criteria:**
- [ ] Create, rename, favorite, edit, and delete persist offline.
- [ ] Two devices on the same iCloud account converge using stable IDs and latest-update conflict rules.
- [ ] iCloud errors never remove the local copy.

**Verification:**
- [ ] Unit-test serialization, migration, and merge conflicts.
- [ ] Physical two-device iCloud sync check when a second supported device is available; until then, use two isolated stores in integration tests.

**Dependencies:** Task 5.

**Files likely touched:** `Focelle/Filters/UserPreset.swift`, `Focelle/Filters/PresetStore.swift`, `Focelle/Filters/PresetSync.swift`, `Focelle/Filters/FilterPickerView.swift`, `FocelleTests/PresetSyncTests.swift`.

**Estimated scope:** Medium (5 files).

### Task 7: Apply presets to an existing photo

**Description:** Add a minimal Photos picker/editor that reuses the same renderer and preset editor, then saves a new copy.

**Acceptance criteria:**
- [ ] Selecting, editing, comparing, canceling, and exporting one image works.
- [ ] Original Photos assets are never overwritten or deleted.
- [ ] Large-image errors are handled without losing the edit draft.

**Verification:**
- [ ] Integration-test editor state with synthetic image fixtures.
- [ ] Physical Photos pick/edit/save check at multiple resolutions.

**Dependencies:** Tasks 4-6.

**Files likely touched:** `Focelle/Filters/PhotoEditorView.swift`, `Focelle/Filters/PhotoEditorModel.swift`, `Focelle/App/AppRoute.swift`, `Focelle/Filters/FilterRenderer.swift`, `FocelleTests/PhotoEditorTests.swift`.

**Estimated scope:** Medium (5 files).

## Checkpoint B: Camera and Color

- [ ] Camera capture and existing-photo editing use the same owned color pipeline.
- [ ] Preview/export consistency and memory behavior pass on iPhone 17e.
- [ ] Custom presets survive restart/offline and simulated sync conflicts.
- [ ] User approves the 12-look contact sheet and editor interaction recording.

## Phase 3: AI Guidance Vertical Slice

### Task 8: Add continuous on-device scene measurements

**Description:** Sample camera frames at an adaptive rate and derive only the measurements needed for subject placement, faces/pose, horizon, exposure, saliency, and stability.

**Acceptance criteria:**
- [ ] Analysis never blocks preview or shutter.
- [ ] Thermal/load pressure reduces analysis frequency rather than crashing.
- [ ] Measurements contain no identity recognition and are not persisted.

**Verification:**
- [ ] Unit-test coordinate conversion and measurement stabilization with synthetic observations.
- [ ] Profile CPU, memory, and thermal behavior on iPhone 17e for a 10-minute session.

**Dependencies:** Task 3.

**Files likely touched:** `Focelle/AI/SceneMeasurement.swift`, `Focelle/AI/OnDeviceAnalyzer.swift`, `Focelle/AI/MeasurementStabilizer.swift`, `Focelle/Camera/CameraSession.swift`, `FocelleTests/MeasurementTests.swift`.

**Estimated scope:** Medium (5 files).

### Task 9: Render stable AR guidance

**Description:** Convert on-device measurements into a subject target, arrows, short localized instruction, alignment state, and optional haptics.

**Acceptance criteria:**
- [ ] Guidance begins within 500 ms of a usable frame and does not flicker between contradictory commands.
- [ ] Overlays remain correct in front/rear and portrait/landscape coordinates.
- [ ] Color is never the only guidance signal.

**Verification:**
- [ ] Unit-test guidance state transitions and coordinate transforms.
- [ ] Physical walk-through for single person, couple, group, and no-subject scenes.

**Dependencies:** Task 8.

**Files likely touched:** `Focelle/AI/GuidanceEngine.swift`, `Focelle/AI/Guidance.swift`, `Focelle/Camera/GuidanceOverlay.swift`, `Focelle/Camera/CameraView.swift`, `FocelleTests/GuidanceEngineTests.swift`.

**Estimated scope:** Medium (5 files).

### Task 10: Build the validated cloud-AI request path

**Description:** Create a minimal Cloudflare Worker/D1 backend that accepts an authenticated app request, strips metadata, calls Gemini with a reduced preview, validates strict JSON, and returns one primary plus two alternative plans.

**Acceptance criteria:**
- [ ] Provider keys exist only as Worker secrets.
- [ ] Malformed output, timeout, rate limit, and provider errors map to stable app error codes.
- [ ] The backend never persists the preview or response text.

**Verification:**
- [ ] Worker unit/integration tests cover auth, size/type validation, timeout, schema failure, and rate limiting.
- [ ] `npm --prefix backend test` and `npm --prefix backend run typecheck` pass.

**Dependencies:** Approved AI schema from Tasks 8-9.

**Files likely touched:** `backend/src/index.ts`, `backend/src/analyze.ts`, `backend/src/schema.ts`, `backend/test/analyze.test.ts`, `backend/wrangler.jsonc`.

**Estimated scope:** Medium (5 files).

### Task 11: Connect AI tap to actionable camera guidance

**Description:** Capture/compress a preview, call the Worker, show loading/cancel/error states, apply safe camera changes, confirm flash/filter, support long-press subject selection, and reuse alternatives without a second charge.

**Acceptance criteria:**
- [ ] One tap produces one primary and two reusable alternatives.
- [ ] Timeout/offline/invalid response falls back without spending a credit.
- [ ] Selected subject, zoom, overlay, and supported exposure changes agree.

**Verification:**
- [ ] Integration-test the full state machine with stubbed responses/errors.
- [ ] Physical single/couple/group tests on at least 30 consented scenes before quality claims.

**Dependencies:** Tasks 9-10.

**Files likely touched:** `Focelle/AI/AIClient.swift`, `Focelle/AI/AIAnalysisState.swift`, `Focelle/AI/Guidance.swift`, `Focelle/Camera/CameraView.swift`, `FocelleTests/AIAnalysisStateTests.swift`.

**Estimated scope:** Medium (5 files).

### Task 12: Add optional voice and Auto Capture

**Description:** Add off-by-default speech guidance and a guarded Auto Capture state that requires stable alignment and face readiness without preventing manual shutter.

**Acceptance criteria:**
- [ ] Voice respects mute/settings and does not repeat rapidly.
- [ ] Auto Capture cancels immediately on movement, subject loss, manual capture, or user cancel.
- [ ] Manual/volume shutter remains available in every state.

**Verification:**
- [ ] Unit-test Auto Capture timing/cancellation state transitions.
- [ ] Physical false-positive/eyes-closed/movement checks in varied lighting.

**Dependencies:** Task 11.

**Files likely touched:** `Focelle/AI/VoiceGuidance.swift`, `Focelle/Camera/AutoCapture.swift`, `Focelle/Camera/CameraView.swift`, `Focelle/Camera/CameraSession.swift`, `FocelleTests/AutoCaptureTests.swift`.

**Estimated scope:** Medium (5 files).

## Checkpoint C: AI Camera

- [ ] On-device guidance works offline and Gemini guidance works through the Worker.
- [ ] AI errors never block capture or consume a credit.
- [ ] Median/P95 latency and failure categories are measured, not guessed.
- [ ] User compares guided vs unguided results on a consented photo set and approves the core experience.

## Phase 4: Beta Operations and Trust

### Task 13: Add settings, privacy choices, and accessibility

**Description:** Add Vietnamese/English strings, permissions explanations, on-device-only mode, analytics opt-out, location/save-original/voice/Auto Capture/resolution settings, and accessibility behavior.

**Acceptance criteria:**
- [ ] No permission is requested before the related feature needs it.
- [ ] Vietnamese and English have no missing user-facing strings.
- [ ] VoiceOver, Dynamic Type, contrast, Reduce Motion, and color-independent guidance pass the checklist.

**Verification:**
- [ ] Localization completeness test and settings persistence tests pass.
- [ ] Physical accessibility checklist on iPhone 17e.

**Dependencies:** Tasks 3, 7, and 12.

**Files likely touched:** `Focelle/App/SettingsView.swift`, `Focelle/App/AppSettings.swift`, `Focelle/App/Localizable.xcstrings`, `Focelle/App/PrivacyView.swift`, `FocelleTests/AppSettingsTests.swift`.

**Estimated scope:** Medium (5 files).

### Task 14: Implement remote beta entitlement and anonymous analytics

**Description:** Implement remotely configurable Beta Pro, activation counting, the 60-day/500-user rule, minimal anonymous events, and offline-safe local caching.

**Acceptance criteria:**
- [ ] Beta users see unlimited features and no ads while the server flag is active.
- [ ] Activation requires three successful AI analyses and is idempotent.
- [ ] Events contain no photos, prompts, response text, face geometry, exact location, or advertising identifier.

**Verification:**
- [ ] App tests cover offline cache and beta transitions.
- [ ] Worker tests cover event allowlists, activation idempotency, and remote configuration.

**Dependencies:** Tasks 10-13.

**Files likely touched:** `Focelle/Commerce/BetaAccess.swift`, `Focelle/App/Analytics.swift`, `backend/src/beta.ts`, `backend/src/events.ts`, `backend/test/beta.test.ts`.

**Estimated scope:** Medium (5 files).

### Task 15: Implement quota and rewarded-ad behavior behind flags

**Description:** Implement post-beta daily allowance, reward grants, five-ad cap, dismissible exhaustion sheet, and non-personalized rewarded-ad test mode while leaving production ads disabled.

**Acceptance criteria:**
- [ ] Five daily AI/filter credits, reward of 3 AI + 5 filters, and five-ad cap are server-authoritative.
- [ ] Preview is free; only successful AI taps/filter saves count.
- [ ] Ad load/display/reward failure never blocks camera or grants duplicate credit.

**Verification:**
- [ ] State/Worker tests cover reset, concurrency, duplicate callbacks, offline state, and refund behavior.
- [ ] Google test-ad physical flow passes with production ad unit IDs absent.

**Dependencies:** Task 14.

**Files likely touched:** `Focelle/Commerce/Quota.swift`, `Focelle/Commerce/RewardedAd.swift`, `Focelle/Commerce/LimitSheet.swift`, `backend/src/quota.ts`, `backend/test/quota.test.ts`.

**Estimated scope:** Medium (5 files).

## Checkpoint D: Free Beta

- [ ] Beta Pro is unlimited and ad-free but remotely reversible.
- [ ] Privacy/analytics data flow matches the spec and App Store declarations.
- [ ] Post-beta quota/reward behavior passes tests while hidden.
- [ ] User approves onboarding, settings, limit sheet, and privacy copy.

## Phase 5: Commerce and Referral Safety Net

### Task 16: Add StoreKit subscription and restore flow

**Description:** Add sandbox monthly/yearly products, entitlement status, restore/manage subscription UI, and server notification verification behind disabled production flags.

**Acceptance criteria:**
- [ ] Purchase, cancel/expire, revoke, restore, and offline cached entitlement states are correct.
- [ ] Product IDs/prices come from StoreKit, not hardcoded display strings.
- [ ] Store failure leaves camera and beta access unchanged.

**Verification:**
- [ ] StoreKit configuration tests and App Store sandbox transaction tests pass.
- [ ] Worker tests verify signed notification idempotency/revocation.

**Dependencies:** Task 14.

**Files likely touched:** `Focelle/Commerce/Store.swift`, `Focelle/Commerce/PaywallView.swift`, `Focelle/Commerce/StoreKit.storekit`, `backend/src/store.ts`, `backend/test/store.test.ts`.

**Estimated scope:** Medium (5 files).

### Task 17: Add Sign in with Apple and consumable balance sync

**Description:** Request Sign in with Apple only at consumable purchase/sync, connect verified identity to minimal backend records, sync non-expiring credits, and support account deletion.

**Acceptance criteria:**
- [ ] Free camera use never requires login.
- [ ] Consumable balance converges across signed-in devices without double granting.
- [ ] Delete Account removes backend account data while preserving legally required transaction records only.

**Verification:**
- [ ] Tests cover nonce/auth failure, duplicate transactions, sync conflicts, logout, and deletion.
- [ ] Physical sandbox purchase/sync flow passes across available test devices/accounts.

**Dependencies:** Task 16.

**Files likely touched:** `Focelle/Commerce/AppleSignIn.swift`, `Focelle/Commerce/CreditBalance.swift`, `Focelle/Commerce/AccountView.swift`, `backend/src/account.ts`, `backend/test/account.test.ts`.

**Estimated scope:** Medium (5 files).

### Task 18: Add referral behind the monetization flag

**Description:** Add share/entry flow and an idempotent backend reward after the referred user's first verified purchase.

**Acceptance criteria:**
- [ ] Referrer gets 30 AI credits exactly once after a qualifying purchase.
- [ ] Referred user receives a valid seven-day Pro/offer-code benefit.
- [ ] Self-referral, repeat redemption, refund, and revoked purchase paths are handled.

**Verification:**
- [ ] Backend tests cover fraud guards, idempotency, refund/revocation, and code expiration.
- [ ] Sandbox offer-code/referral flow passes before production flag enablement.

**Dependencies:** Tasks 16-17.

**Files likely touched:** `Focelle/Commerce/ReferralView.swift`, `Focelle/Commerce/Referral.swift`, `backend/src/referral.ts`, `backend/src/store.ts`, `backend/test/referral.test.ts`.

**Estimated scope:** Medium (5 files).

## Checkpoint E: Monetization Ready but Disabled

- [ ] StoreKit, restore, consumable sync, deletion, test rewarded ads, and referral pass sandbox/test modes.
- [ ] Production product/ad IDs and monetization flag remain disabled during free beta.
- [ ] No real charge, ad campaign, or App Store submission occurs without explicit user authorization.

## Phase 6: Release Hardening

### Task 19: Harden camera, AI, and render performance

**Description:** Fix measured memory, orientation, thermal, latency, and interruption issues from extended device sessions; do not add speculative optimizations.

**Acceptance criteria:**
- [ ] Ten-minute continuous sessions survive camera interruptions, background/foreground, network changes, and memory pressure.
- [ ] 24/48 MP render/save behavior meets measured device limits without data loss.
- [ ] Cloud latency/error targets are reported with evidence.

**Verification:**
- [ ] Instruments/device logs and the full physical matrix are attached as release evidence.
- [ ] CI tests remain green after each targeted fix.

**Dependencies:** Checkpoints A-E.

**Files likely touched:** Only the measured hot/failing paths plus focused regression tests (maximum 5 per fix).

**Estimated scope:** Multiple small targeted fixes, not one bulk rewrite.

### Task 20: Prepare TestFlight beta and support materials

**Description:** Finalize icon/launch assets, privacy/support copy, App Store privacy answers, TestFlight notes, signed cloud archive, and a staged internal beta release.

**Acceptance criteria:**
- [ ] Trademark check and seller/privacy/support details are documented.
- [ ] Signed archive validates and uploads to TestFlight from CI.
- [ ] Internal testers can install, complete onboarding, capture, use AI/filter/editor, and submit feedback.

**Verification:**
- [ ] App Store validation succeeds without hidden/private APIs or missing disclosures.
- [ ] Fresh-install TestFlight checklist passes on iPhone 17e.

**Dependencies:** Task 19 and explicit authorization for Apple Developer/App Store actions.

**Files likely touched:** `Focelle/Assets.xcassets`, `Focelle/Info.plist`, `.github/workflows/testflight.yml`, `docs/privacy.md`, `docs/testflight-checklist.md`.

**Estimated scope:** Medium (5 files).

## Final Checkpoint

- [ ] Every approved spec success criterion is linked to passing automated or physical evidence.
- [ ] No secrets or personal photos exist in source control or artifacts.
- [ ] Beta Pro is active, ads/paid products/referral are production-disabled, and rollback flags are tested.
- [ ] User approves the TestFlight build before any public App Store submission.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| No local Mac/Xcode | High | Prove unsigned macOS CI build first; stop before feature work if it fails. |
| Custom camera produces worse output than Apple Camera | High | Use AVFoundation quality prioritization, compare owned scenes early, default 24 MP, preserve original on render failure. |
| AI spatial advice is vague or wrong | High | Let Vision own coordinates; strict JSON; fixed evaluation set; on-device fallback; never auto-apply unsafe changes. |
| Gemini free-tier privacy/limits | High | Explicit beta consent, reduced preview, no retention by Focelle, on-device-only mode, migrate before public scale. |
| Camera/AI/filter heat or memory pressure | High | Adaptive frame sampling, shared renderer, background full-res render, device profiling before polish. |
| iCloud preset conflicts | Medium | Stable IDs, versioned records, latest-update merge, never delete local data on cloud error. |
| Quota/purchase/referral fraud | Medium | Server authority, signed StoreKit events, idempotency keys, rate limits, delayed verified rewards. |
| Ads harm trust | Medium | Rewarded only, non-personalized, user-triggered, capped, disabled throughout beta. |
| Free beta causes monetization backlash | Medium | Persistent Beta Pro label, explicit 60-day/500-user boundary, founder benefit. |
| Scope expands into a full editor/social app | Medium | Enforce approved out-of-scope list and ask before changing the spec. |

## Prerequisites Requested Only When Reached

- GitHub repository access for Actions.
- Apple Developer membership and App Store Connect access before signed device/TestFlight work.
- Cloudflare account and a Worker/D1 environment before Task 10.
- Google AI Studio Gemini key before Task 10; stored only as a Worker secret.
- A second iCloud-capable test device/account session before claiming real cross-device sync.
- Google AdMob account only before Task 15 test-ad integration.

Do not request or store these credentials in documentation or source files.

## Approval Gate

After approval, convert these tasks into the active checklist and implement one task at a time. Pause for the named checkpoints and any action requiring a paid account, credentials, external publication, or real charge.
