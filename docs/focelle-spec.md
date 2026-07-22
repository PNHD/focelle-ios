# Spec: Focelle iOS Beta

## Status

Draft for user review. No implementation begins until this document is approved.

## Objective

Build a commercial iPhone camera for photography beginners in Vietnam. Focelle guides people to a better portrait, couple, or small-group photo before they press the shutter, using real-time on-device measurements plus deeper scene advice on demand.

Primary launch language is Vietnamese with English included from the first release. The beta is free; Android, iPad, and video are out of scope.

### Core user outcome

A person with no photography knowledge can open Focelle, point at one person, a couple, or a small group, and get a visibly better composition, angle, exposure, and color than an unguided attempt within about 10 seconds.

### Product principles

- Open directly to the camera; never require an account before shooting.
- Keep the shutter, basic camera controls, and saving available when AI/filter credits run out.
- Use visual AR guidance first, one short sentence second, and optional voice guidance third.
- Preserve natural faces and bodies. Do not reshape faces/bodies or apply plastic skin smoothing.
- Do not watermark output by default.
- Do not store user photos or AI prompt content in analytics.

## Supported Platform

- iPhone only; portrait and landscape capture.
- Minimum deployment target: iOS 18.1.
- Baseline: iPhone 11 and newer using Vision/Core ML plus cloud vision.
- Enhanced tier: iPhone 15 Pro and newer when Apple Intelligence is enabled.
- Primary physical test device: iPhone 17e on iOS 26.
- iPad, Android, Live Photo, burst, panorama, RAW/ProRAW, and video are not in the beta.

## User Experience

### First run

1. Show a short Vietnamese introduction with an English alternative.
2. Explain that AI analysis sends a reduced-resolution preview to the configured AI provider and that on-device guidance remains available without it.
3. Request camera permission.
4. Request Photos add permission only when saving the first image.
5. Do not request location, tracking, microphone, notification, or account permissions during onboarding.
6. Open the viewfinder.

### Camera

- Front and rear cameras.
- Photo ratios: 4:3, 1:1, and 16:9.
- Timer, grid, flash, tap-to-focus, exposure bias, zoom, camera switching, and volume-button shutter.
- Default output is 24 MP where supported; Settings can enable 48 MP on compatible hardware.
- Save HEIF/JPEG to Apple Photos. Show only the latest thumbnail; do not build a duplicate in-app gallery.
- When a filter is active, save the rendered image. An off-by-default setting can also preserve the original.
- Location metadata is off by default and requested only if the user enables it. Location is never sent to AI or analytics.
- Auto Capture is optional and off by default. It may capture after composition is aligned, the phone is stable, and detected faces are ready. Manual shutter always wins.

### AI composition flow

1. On-device analysis continuously measures subject boxes, faces/pose, saliency, horizon, stability, exposure, and available camera capabilities.
2. Long-pressing the preview selects the intended subject when detection is ambiguous.
3. Tapping AI captures a reduced-resolution preview and spends at most one AI credit.
4. The cloud model returns structured advice: target framing, movement, angle, zoom, exposure/flash recommendation, pose, and suitable presets.
5. Focelle immediately shows the best composition using arrows/target frames and one short instruction.
6. "Goc khac" reveals Safe and Creative alternatives from the same result without another charge.
7. AI may apply safe changes such as zoom and supported camera parameters automatically. Flash and filter changes require one-tap confirmation.
8. An AI failure, timeout, or invalid response refunds/reserves no credit and falls back to on-device guidance.

Voice guidance is optional and off by default. Guidance must not repeat continuously or obscure the subject.

### Performance targets

- Camera preview remains responsive while on-device analysis runs.
- On-device guidance begins within 500 ms after a usable frame is available.
- Cloud guidance target: median under 3 seconds, 95th percentile under 8 seconds.
- Cancel cloud analysis after 10 seconds and keep the camera usable.
- No shutter delay caused by analytics, quota sync, referral, or ad services.

## Filters and Presets

### Focelle Originals

Ship 12 original, trademark-neutral looks created from owned parameter recipes rather than redistributed third-party LUT packs:

1. Neutral Skin
2. Clean Bright
3. Soft Portrait
4. Warm Glow
5. Golden Hour
6. Cafe Amber
7. Travel Vivid
8. Cool Air
9. Night Neon
10. Faded Film
11. Matte Grain
12. Mono Contrast

Do not use Kodak, Fuji, Leica, VSCO, or other third-party brand names. Any future third-party LUT must have explicit rights for embedding and redistribution inside a commercial app.

### Editing

- Live preview is always free.
- Count a filter credit only when saving an image with a filter.
- Primary editor mirrors the supplied reference: a two-dimensional Tone x Color pad plus an Intensity slider.
- Advanced controls: exposure, highlights, shadows, contrast, saturation, warmth, tint, fade, grain, and vignette.
- Press and hold to compare with the original; Reset restores the base preset.
- Users can name, favorite, edit, and delete custom presets.
- Custom preset records sync between devices through the user's private iCloud account and remain available offline.
- The beta also allows selecting one existing Photos image, applying the same preset editor, and saving a copy. It is not a general-purpose photo editor.

## AI Architecture

### Beta

- Vision/Core ML performs continuous geometry and quality measurements on device.
- Gemini free tier performs deeper image understanding only after an AI tap.
- Send only a reduced-resolution, correctly oriented preview through the backend; never ship an AI provider key in the app.
- Clearly disclose that the Gemini free tier may use submitted content to improve Google products. Offer on-device-only mode.
- Gemini output must conform to a strict, versioned JSON schema and be validated before use.
- DeepSeek V4 is not used because its official API is currently text-only.

### Later

- Move production traffic to a paid provider/privacy tier before public scale requires it.
- Add Apple Foundation Models image analysis behind availability checks when the stable OS/runtime supports it.
- Compare provider changes using the same consented 100-200-image evaluation set for advice quality, spatial accuracy, latency, failures, and cost per successful result.

## Beta, Quotas, Ads, and Purchases

### Free beta

- Display "Beta Pro - mien phi trong giai doan thu nghiem."
- Unlock all AI analyses, filters, and custom presets.
- Show no ads during the beta.
- End beta after 60 days or 500 activated users, whichever occurs first.
- Activation means completing at least three successful AI analyses.
- At monetization launch, beta users receive 30 days of Pro and 100 AI credits.

### Post-beta free allowance

- Five AI taps and five filter saves per local calendar day.
- A user-initiated rewarded ad grants three AI credits and five filter credits.
- Maximum five rewarded ads per day.
- No banners, interstitials, forced ads, or personalized ads.
- If limits are exhausted, show a dismissible bottom sheet with rewarded-ad and purchase choices; never replace or discard the current viewfinder.

### Purchases

- Offer both consumable credit packs and affordable monthly/yearly Pro subscriptions for Vietnam.
- Exact prices and paid quotas are set after measured production AI/ad unit economics; initial target is 29,000 VND entry packs and 79,000-99,000 VND monthly Pro.
- Do not offer weekly or lifetime plans initially.
- Use StoreKit 2. Purchased credits never expire.
- Subscription entitlement restores through the App Store.
- Sign in with Apple appears only when purchasing consumable credits, syncing purchased balance, or managing/deleting the resulting Focelle account.

### Referral

- Enable referral only when monetization launches.
- After a referred user's first verified purchase, grant the referrer 30 AI credits and the referred user seven Pro days or an equivalent first-purchase offer.
- Block self-referrals and duplicate rewards. Handle refunds/revocations.
- Never reward App Store ratings or reviews.

## Privacy and Security

- No cross-app tracking; do not request App Tracking Transparency.
- Rewarded ads must be non-personalized.
- Do not perform face recognition or infer identity, ethnicity, health, attractiveness, or other sensitive traits.
- Do not retain AI preview images in Focelle storage after the request completes.
- Encrypt network traffic and keep provider, signing, and App Store credentials only in server-side secrets.
- Rate-limit AI, reward, purchase, and referral endpoints. Client counters are display hints; the backend is authoritative after beta.
- Store presets in the user's private iCloud storage. Store only minimal account, entitlement, quota, and anonymous event data in the backend.
- Provide an in-app privacy explanation, analytics opt-out, Sign in with Apple account deletion, purchase restore, and data deletion path.
- Basic camera/filter behavior must continue offline. Offline AI taps do not spend credits.

## Analytics

Anonymous analytics is on by default with a Settings opt-out. Record only events needed to evaluate the beta:

- Onboarding and permission outcomes.
- AI tap, success/failure category, latency bucket, and schema version.
- Guidance followed/aligned, alternative selected, and capture after guidance.
- Filter/preset selection and save success.
- Activation, day-1/day-7 return, reward completion, purchase, restore, and referral outcome.

Never record an image, prompt/response text, face geometry, exact location, advertising identifier, or cross-app identifier.

## Brand and Accessibility

- Working name: Focelle.
- App Store subtitle: "Focelle - AI Photo Coach" (localized before submission).
- Visual direction: charcoal/black camera chrome, ivory text, warm amber accent; no generic purple-blue AI gradient.
- Icon direction: minimal viewfinder plus light cue.
- Tone: short, warm, practical, and free of photography jargon.
- Vietnamese default with full English localization.
- Support VoiceOver labels, Dynamic Type outside the viewfinder, sufficient contrast, shapes/text in addition to color, haptics that respect system settings, and Reduce Motion.
- No default watermark. Optional signatures/frames are user-controlled.

## Tech Stack

- Swift 6 and SwiftUI.
- AVFoundation for capture and camera controls.
- Vision/Core ML for on-device measurements.
- Core Image/Metal-backed rendering for filters and color cubes.
- PhotoKit for saving and selecting images.
- iCloud key-value/private storage for small preset records and offline-first sync.
- StoreKit 2 and App Store Server APIs for purchases.
- AuthenticationServices for Sign in with Apple when required.
- Cloudflare Workers + D1 for provider proxying, feature flags, quota, minimal accounts, analytics, and referrals.
- Gemini API for beta cloud vision.
- Google Mobile Ads SDK for post-beta rewarded ads only.
- GitHub Actions or Codemagic macOS runners for Xcode build/test/signing from this Windows workspace.

Avoid a React Native bridge, a duplicate media backend, a social feed, a custom account system before purchase, and third-party LUT redistribution.

## Commands

Commands run on a macOS CI runner with the selected Xcode version:

```bash
# Build without signing
xcodebuild -project Focelle.xcodeproj -scheme Focelle -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Unit and integration tests
xcodebuild -project Focelle.xcodeproj -scheme Focelle -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# Format check
swift format lint --recursive --strict Focelle FocelleTests

# Backend checks
npm --prefix backend ci
npm --prefix backend test
npm --prefix backend run typecheck

# Run backend locally
npm --prefix backend run dev
```

Physical camera, Photos, iCloud, StoreKit sandbox, rewarded ads, and Auto Capture require checks on the iPhone 17e.

## Project Structure

```text
Focelle.xcodeproj/        Xcode project
Focelle/
  App/                    lifecycle, navigation, localization, theme
  Camera/                 AVFoundation session, preview, capture, guidance
  AI/                     on-device measurements, cloud client, schemas
  Filters/                original recipes, renderer, preset editor/sync
  Commerce/               quota, StoreKit, rewards, referral, account
  Shared/                 small cross-feature models and utilities only
FocelleTests/             focused unit/integration tests
backend/                  Cloudflare Worker, D1 migrations, provider proxy
docs/                     approved specification and privacy/support drafts
```

Do not create a helper, protocol, service layer, or dependency until a second real caller/implementation requires it.

## Code Style

Prefer concrete Swift types, value models, structured concurrency, dependency injection through initializers, and explicit error states.

```swift
struct Guidance: Decodable, Equatable {
    let instruction: String
    let movement: Movement
    let zoomFactor: Double?
    let recommendsFlash: Bool
}

func analyze(_ preview: Data) async throws -> Guidance {
    let response = try await client.send(preview)
    return try validator.decode(response)
}
```

- Types: `UpperCamelCase`; properties/functions: `lowerCamelCase`.
- Prefer `async/await`; do not add callback wrappers unless an Apple API requires one.
- No force unwraps in production paths.
- Localized user-facing strings only; no inline Vietnamese/English in views.
- Comments explain a non-obvious constraint, not the code itself.

## Testing Strategy

- One focused test per non-trivial branch/parser/state transition; no arbitrary coverage target.
- Unit-test quota resets/rewards, credit refunds, filter recipe serialization, preset merge conflicts, AI JSON validation, entitlement/referral transitions, and orientation transforms.
- Use recorded/synthetic metadata rather than personal photos in the repository.
- Integration-test Worker authentication, rate limiting, provider timeouts, malformed AI output, StoreKit sandbox notifications, and referral idempotency.
- Test filter rendering against small owned reference images with perceptual tolerances.
- Physical-device checklist covers permission denial/recovery, front/rear cameras, portrait/landscape, 24/48 MP, focus/zoom/flash, Auto Capture, Photos save, iCloud sync, offline fallback, thermal behavior, and memory pressure.
- Accessibility check covers VoiceOver, large text, contrast, Reduce Motion, and color-independent guidance.

## Boundaries

### Always

- Keep the camera usable through AI, network, quota, ad, and purchase failures.
- Validate all external input and AI output.
- Protect user photos, secrets, entitlements, and credits.
- Use owned filter recipes or assets with explicit commercial redistribution rights.
- Run relevant automated checks and a physical-device checklist before claiming completion.
- Update this spec before changing approved scope.

### Ask first

- Add a paid dependency or analytics/ad SDK beyond those named here.
- Change the minimum iOS/device support.
- Store or retain user images.
- Change quota, reward, price, referral, beta-end, or privacy behavior.
- Add authentication before the user purchases/syncs credits.
- Add video, social, beauty alteration, or generative image features.

### Never

- Commit API keys, certificates, provisioning profiles, or user photos.
- Ship provider keys in the iOS binary.
- Spend real money or publish to the App Store without explicit authorization.
- Reward ratings/reviews, show forced ads, or track users across apps.
- Claim a cloud build or camera flow works without CI and physical-device evidence.

## Success Criteria

The beta is ready only when all are true:

1. A new user reaches a working camera without creating an account.
2. Portrait, couple, and small-group scenes receive one primary and two optional composition plans from one AI tap.
3. AR guidance remains stable enough to follow and does not block the subject or shutter.
4. AI-guided capture, manual capture, filter preview/save, custom presets, and existing-photo editing work on iPhone 17e.
5. Presets sync across two devices on the same iCloud account and remain usable offline.
6. Cloud failure, timeout, invalid output, lost network, exhausted quota, ad failure, and purchase failure leave the camera usable and do not incorrectly spend credits.
7. Output is correctly oriented, color-managed, and saved at the selected supported resolution without an automatic watermark.
8. Beta Pro is remotely configurable and automatically reports progress toward 60 days/500 activated users.
9. StoreKit sandbox purchases/restores, rewarded-ad test mode, Sign in with Apple, deletion, and referral idempotency pass before their production flags can be enabled.
10. No secrets or personal test images are present in the repository, and privacy disclosures match measured data flows.
11. Automated macOS CI build/tests pass, followed by the physical-device checklist on iPhone 17e.

## Open Questions Deferred by Design

- Exact paid credit-pack sizes, Pro quotas, and Vietnam prices depend on measured provider cost, rewarded-ad yield, and beta usage.
- The production vision provider is selected from the fixed evaluation set before beta monetization.
- Final legal trademark clearance for Focelle and final App Store seller/privacy documents occur before public submission.
