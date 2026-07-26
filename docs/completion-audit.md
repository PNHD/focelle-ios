# Focelle Beta Completion Audit

Audited on 2026-07-26 against `docs/focelle-spec.md` and
`docs/focelle-plan.md`. Public GitHub Actions run
[`30208737163`](https://github.com/PNHD/focelle-ios/actions/runs/30208737163)
passed the formatted source baseline recorded here.

## Current automated evidence

- Backend: 29 tests passed across 6 files; TypeScript and generated Worker
  bindings type-check.
- Worker: `wrangler deploy --dry-run` bundles successfully with D1 and both
  rate-limit bindings. The Worker is not deployed because its required
  Gemini and app-token secrets are not available.
- D1: remote database `focelle-beta` has migrations 0001-0007. The two newest
  migrations were verified remotely, and all commerce/account/referral flags
  remain off.
- iOS: run `30208737163` passed strict Swift formatting, booted the iPhone 17e
  simulator, built the app, passed all 26 tests, launched the app, captured
  onboarding, and uploaded the logs, screenshot, and xcresult artifact.
  Simulator builds intentionally retain presets locally because unsigned
  simulators cannot use CloudKit; signed-device sync remains a release gate.
- AI lifecycle: cancel, background, and on-device-only transitions clear both
  pending preview capture and in-flight network work; a late sender failure
  after cancellation is covered by an automated regression test.
- TestFlight workflow: signed archives are no longer uploaded as public CI
  artifacts; only export diagnostics remain available.
- Repository: no provider key, certificate, provisioning profile, personal
  photo, or production ad unit is expected in source. Re-run the secret/file
  scan immediately before push.

## Approved success criteria

| # | Criterion | Current evidence | Remaining release evidence |
|---|---|---|---|
| 1 | Camera without account | Onboarding routes directly to `CameraView`; signed-out account entry is absent outside credit purchase | Fresh-install iPhone capture |
| 2 | Primary + Safe + Creative from one tap | Strict iOS and Worker schema requires exactly three plans; automated schema tests pass | Deployed Gemini path and consented scene evaluation |
| 3 | Stable, non-blocking AR guidance | Stabilization, command debounce, arrows, text, color-independent icons, and manual shutter path are implemented | Walk-through and flicker/occlusion check on iPhone |
| 4 | Guided/manual capture, filters, presets, existing-photo editing | All paths are connected in the app; filter quota also covers existing-photo saves | Full iPhone interaction matrix |
| 5 | Private iCloud sync and offline presets | Local atomic store, tombstone merge, CloudKit private database, and iCloud entitlements are present | Apple container provisioning and two-device convergence |
| 6 | Failures keep camera usable and preserve credits | Worker reserves/commits/refunds AI credits; UI errors do not replace the viewfinder; backend failure tests pass | Network/ad/purchase failure tests on device and sandbox |
| 7 | Orientation, color, resolution, no watermark | Orientation mapping, owned Core Image pipeline, supported 24/48 MP selection, original fallback, and no watermark code are present | Front/rear portrait/landscape output inspection |
| 8 | Remote 60-day/500-user Beta Pro | D1 rules, three-success activation, milestone analytics, cache, and remote flags are implemented and tested | Deployed Worker health/config call |
| 9 | Commerce safety net before enablement | StoreKit 2, signed server verification, non-personalized test reward, Sign in with Apple, deletion retention, and referral idempotency are implemented behind off flags | Apple sandbox, AdMob test, account, deletion, and referral device flows |
| 10 | Privacy and repository hygiene | Metadata stripping, strict analytics allowlists, privacy manifest/policy drafts, and server-side provider credentials are implemented | Final secret scan, Xcode privacy report, public support/privacy details |
| 11 | Passing macOS CI then physical checklist | Public run `30208737163` passed backend, strict formatting, 26 iOS tests, simulator launch, and screenshot capture | Signed archive and iPhone 17e checklist |

## Mandatory external gates

1. Supply a Gemini API key and set a generated app token in both Cloudflare
   and GitHub Secrets; deploy and smoke-test the Worker.
2. Enable Sign in with Apple and CloudKit container
   `iCloud.com.pnhd.focelle` in the Apple App ID and provisioning profile.
3. Supply Apple Developer/App Store Connect signing material plus seller,
   support, and privacy-policy details.
4. Run the physical iPhone 17e checklist, including a second iCloud device,
   StoreKit sandbox, AdMob test mode/consent, and the ten-minute performance
   session.
5. Obtain explicit authorization before any TestFlight upload or public App
   Store action.

Keep the repository public during beta CI, then switch it back to private
after release. Until the remaining gates pass, the beta is implemented and
CI-verified but not releasable.
