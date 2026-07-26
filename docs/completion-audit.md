# Focelle Beta Completion Audit

Audited on 2026-07-26 against `docs/focelle-spec.md` and
`docs/focelle-plan.md`. The audited local source ends at commit `5c22606`;
this audit refresh is the next commit.

## Current automated evidence

- Backend: 29 tests passed across 6 files; TypeScript and generated Worker
  bindings type-check.
- Worker: `wrangler deploy --dry-run` bundles successfully with D1 and both
  rate-limit bindings. The Worker is not deployed because its required
  Gemini and app-token secrets are not available.
- D1: remote database `focelle-beta` has migrations 0001-0007. The two newest
  migrations were verified remotely, and all commerce/account/referral flags
  remain off.
- iOS: remote run `30196226607` compiled the app and tests, then the test host
  stopped because the generated app plist omitted the AdMob application ID.
  Commit `8eafb35` replaces that generated plist with an explicit validated
  plist and removes the duplicate CI build. This fix and later Swift changes
  are intentionally not pushed until the GitHub Actions allowance resets.
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
| 11 | Passing macOS CI then physical checklist | Backend checks pass; prior iOS build compiled | One post-reset CI run, signed archive, and iPhone 17e checklist |

## Mandatory external gates

1. Supply a Gemini API key and set a generated app token in both Cloudflare
   and GitHub Secrets; deploy and smoke-test the Worker.
2. After the GitHub Actions allowance resets, push the local commits and run
   the optimized iOS workflow once. Do not retry blindly if it fails.
3. Enable Sign in with Apple and CloudKit container
   `iCloud.com.pnhd.focelle` in the Apple App ID and provisioning profile.
4. Supply Apple Developer/App Store Connect signing material plus seller,
   support, and privacy-policy details.
5. Run the physical iPhone 17e checklist, including a second iCloud device,
   StoreKit sandbox, AdMob test mode/consent, and the ten-minute performance
   session.
6. Obtain explicit authorization before any TestFlight upload or public App
   Store action.

Until those gates pass, the beta is implemented but not verified or releasable.
