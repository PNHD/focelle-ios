# Focelle iOS Beta — Claude Code Handoff

Updated: 2026-07-28 19:10 Asia/Ho_Chi_Minh

## Read first

Continue the existing goal; do not redefine completion around the current
implementation:

> Hoàn thiện Focelle iOS beta từ trạng thái hiện tại đến toàn bộ phạm vi trong
> `docs/focelle-spec.md` và `docs/focelle-plan.md`, triển khai tuần tự, kiểm thử
> CI, đẩy GitHub, và chỉ dừng ở các bước bắt buộc cần tài khoản/chứng chỉ hoặc
> kiểm tra iPhone vật lý của người dùng.

Authoritative order:

1. Current files, test output, Git state, GitHub Actions, device logs.
2. `docs/focelle-spec.md`.
3. `docs/focelle-plan.md`.
4. `docs/completion-audit.md` as an older audit, not current proof.

Do not claim the beta or camera is complete until every spec criterion has
fresh automated or physical evidence. The app currently crashes on the real
iPhone at launch.

## User and product constraints

- Communicate with the user in Vietnamese; the user is not a programmer.
- iOS first, commercial-quality product, Vietnam-first, Vietnamese and English.
- Target physical device: iPhone 17e on iOS 26.x (Sideloadly displayed 26.5).
- The user has Windows and no Mac. Build/test iOS through GitHub Actions macOS.
- Doka Cam is a reference, not a screen or behavior to copy. Focelle should
  cover Doka-like composition guidance and improve it with stable on-device
  geometry plus optional cloud semantic advice.
- Camera must remain usable without login, cloud, ads, quota, or purchases.
- Continuous realtime geometry belongs on-device. Gemini is only for a
  user-triggered semantic analysis.
- Filters must be commercially owned numeric recipes; do not import unlicensed
  LUTs. Users can edit and sync custom presets.
- Beta Pro is unlimited and ad-free while the remote beta flag is active.
- Post-beta defaults in the approved spec: five daily AI uses and five filter
  saves; successful use only. Preview is free.
- One rewarded ad grants three AI credits plus five filter credits, capped at
  five ads per day. Failure must never block the camera or duplicate rewards.
- Referral and StoreKit paths exist behind disabled flags. Do not enable real
  charges, production ads, referral, TestFlight upload, or App Store submission
  without explicit user authorization at the action point.
- Never put provider keys, Apple credentials, certificates, provisioning
  profiles, personal photos, account identifiers, or tokens in source/logs/docs.

## Repository state

- Repository: `PNHD/focelle-ios`
- Pull request: <https://github.com/PNHD/focelle-ios/pull/1>
- Worktree:
  `C:\Users\phamn\Documents\Codex\2026-07-22\build-1-app-ch-p-h\.worktrees\focelle-beta`
- Branch: `feat/focelle-beta`
- Remote tracking: `origin/feat/focelle-beta`
- Baseline HEAD before this handoff: `8bc164315ca9b0b8b1deb0820d37135d45e5ed1e`
  (`ci: package unsigned device IPA`)
- Main working checkout outside this worktree exists, so always run `git status`
  in the exact worktree above.
- `gh` CLI is not authenticated. The connected GitHub app can read Actions
  state; normal `git push` has worked through the Windows credential manager.

Current expected modified/new files before the handoff checkpoint:

- `backend/src/http.ts`
- `backend/test/analyze.test.ts`
- `.ai/SESSION.md`

Do not discard unrelated user changes. Run:

```powershell
git status --short --branch
git diff --check
git diff
```

## Latest CI and unsigned IPA

GitHub Actions commit `8bc1643`:

- Workflow: `iOS`
- Run number: 52
- Run ID: `30214345669`
- URL:
  <https://github.com/PNHD/focelle-ios/actions/runs/30214345669>
- Conclusion: success
- `backend` job: success.
- `build-test-screenshot` job: success.
- Steps proved strict Swift lint, iPhone 17e simulator boot, build/XCTest,
  unsigned device IPA packaging, onboarding screenshot, and artifact upload.
- This does not prove physical camera, Photos, CloudKit, StoreKit, ads, or AI.

Downloaded artifact:

- IPA:
  `C:\Users\phamn\Downloads\Focelle-Beta-run52\Focelle-Beta.ipa`
- IPA SHA-256:
  `60f32dc1e666306d5a4a3890d0fa4b1fe78f8f5dabb5b82acd50124be514dabb`
- It contains `Payload/Focelle.app/Info.plist` and the Focelle executable.
- It intentionally had no `_CodeSignature` or `embedded.mobileprovision`; it
  was re-signed locally by Sideloadly.

## Sideloadly and physical-device state

Installed tool:

- Sideloadly 0.60:
  `C:\Users\phamn\AppData\Local\Sideloadly\Sideloadly.exe`

Completed device steps:

1. iPhone connected and trusted over USB.
2. IPA loaded into Sideloadly by launching Sideloadly with the IPA path as an
   argument. This avoids its oversized child file picker:

   ```powershell
   Start-Process `
     -FilePath 'C:\Users\phamn\AppData\Local\Sideloadly\Sideloadly.exe' `
     -ArgumentList '"C:\Users\phamn\Downloads\Focelle-Beta-run52\Focelle-Beta.ipa"'
   ```

3. User entered Apple credentials manually. Never automate or request them.
4. Sideloadly displayed `Done.` and `100%`.
5. User trusted the developer profile on iPhone.
6. iPhone then requested Developer Mode. The user enabled/restarted or reached
   the point where Focelle can begin launching.
7. Current physical result: **opening Focelle immediately exits/crashes**.

No crash log has been captured yet. This is the immediate blocker and highest
priority bug.

## Physical crash: evidence and leading hypothesis

Observed evidence:

- Installation completed.
- iOS trust and Developer Mode gates were passed far enough for launch.
- The icon is present.
- The process exits immediately on physical launch.
- Simulator onboarding launch in CI succeeded.

Do not present the following as confirmed until a crash report supports it.

Leading hypothesis:

- `FocelleApp.body` starts `.task { await presets.sync() }` at launch.
- On physical devices, `PresetSync.database()` unconditionally calls:

  ```swift
  CKContainer(identifier: identifier).privateCloudDatabase
  ```

- The unsigned CI IPA was re-signed with a free Sideloadly profile. Free
  provisioning may not include the CloudKit container or Sign in with Apple
  entitlements declared in `Focelle/Focelle.entitlements`.
- `CKContainer(identifier:)` can fail outside normal Swift error handling when
  the signed entitlement is absent, so `PresetStore.sync()`'s `do/catch` may
  not protect launch.

Relevant files:

- `Focelle/App/FocelleApp.swift`
- `Focelle/Filters/PresetSync.swift`
- `Focelle/Filters/PresetStore.swift`
- `Focelle/Focelle.entitlements`
- `Focelle/Info.plist`
- `Focelle.xcodeproj/project.pbxproj`

Get evidence first:

1. Reconnect the iPhone by USB.
2. Reproduce one launch crash.
3. Collect the newest Focelle `.ips` report:
   - Prefer Sideloadly's device system/crash log feature if available.
   - Or on iPhone:
     `Cài đặt > Quyền riêng tư & Bảo mật > Phân tích & Cải tiến >
     Dữ liệu phân tích`, then share the newest Focelle report.
4. Record exception type, termination reason, crashed thread, and first Focelle
   stack frames. Do not copy unrelated personal device logs.

If the log confirms missing CloudKit entitlement, the likely minimal fix is:

- Add a build-time `FocelleCloudKitEnabled` switch.
- Default it off for unsigned CI/Sideloadly builds.
- Check it before constructing any `CKContainer`.
- Enable it only in the signed Apple/TestFlight workflow after the App ID and
  provisioning profile include `iCloud.com.pnhd.focelle`.
- Preserve local preset persistence and silently treat unavailable CloudKit as
  offline; launch must never depend on iCloud.
- Add a focused test for the disabled/missing configuration path, then rerun
  simulator CI and physical sideload.

An alternative minimal fix is to stop automatic launch sync and only attempt
sync after a safe capability/configuration check. Do not permanently remove
iCloud support; it is required by the approved spec.

## Backend security fix completed locally but not yet checkpointed

During deployment preflight, a fail-open bug was reproduced:

- `authorized(request, expected)` hashed `expected` even when the Worker secret
  was absent.
- `TextEncoder.encode(undefined)` behaved like an empty string.
- With both the Authorization header and secret missing, hashes matched and
  the endpoint authenticated.

TDD evidence:

1. Added test:
   `fails closed when the shared secret is missing`.
2. Before implementation, targeted test failed as expected:
   expected HTTP 401, received 200.
3. Minimal shared-root fix in `backend/src/http.ts`:

   ```ts
   if (!provided || !expected) return false;
   ```

Fresh post-fix verification on 2026-07-28:

```text
npm test -- test/analyze.test.ts
1 file passed; 12 tests passed

npm test
6 files passed; 30 tests passed

npm run typecheck
wrangler types succeeded; tsc --noEmit succeeded

npm exec -- wrangler deploy --dry-run
exit 0; bundle succeeded
```

Commit this fix with the handoff checkpoint after rechecking the diff. Suggested
message:

```text
fix: fail closed without worker secret
```

## Cloudflare/Gemini state

Backend directory: `backend/`

Current code:

- Cloudflare Worker/D1.
- Gemini model config: `gemini-3.5-flash-lite`.
- Required Worker secrets:
  - `APP_SHARED_TOKEN`
  - `GEMINI_API_KEY`
- Plain variable `APP_APPLE_ID` remains empty until Apple Sign in capability and
  client ID are available.
- D1 database `focelle-beta` and migrations `0001` through `0007` exist.
- Rate-limit bindings exist in `wrangler.jsonc`; no Worker KV binding is used.

Current remote state:

- Wrangler is authenticated to the user's Cloudflare account.
- `wrangler secret list` returned: Worker `focelle-api` not found.
- Therefore the Worker is **not deployed** and has no remote secrets yet.
- No matching Gemini/Focelle secret environment-variable names were found
  locally.
- Dry-run bundles successfully.

Do not deploy before both secrets are safely supplied. Without
`APP_SHARED_TOKEN`, the pre-fix code was fail-open. Even after the fix, an
incomplete deployment would not provide working cloud AI.

Safe next deployment sequence:

1. Verify the user's Gemini credential is actually a Gemini API key accepted by
   the configured model. Do not reuse or reveal old chat tokens blindly.
2. Generate a strong random `APP_SHARED_TOKEN`.
3. Set both values interactively with `wrangler secret put`; do not put secret
   values in command history, docs, source, or chat.
4. Deploy `focelle-api`.
5. Smoke-test `/health`, authenticated `/v1/config`, and a consented/synthetic
   `/v1/analyze` request.
6. Confirm D1 flags:
   - Beta Pro on as approved for beta.
   - production ads off.
   - store sandbox/production off until explicit testing.
   - accounts off.
   - referrals off.
   - reward test off unless running the AdMob test flow.
7. Record endpoint only after deployment succeeds.

The old Cloudflare KV warning is not a reason to upgrade this Worker: this
backend uses D1 plus native rate-limit bindings, not Workers KV.

## Build-time cloud configuration

`Focelle/Info.plist` reads:

- `FOCELLE_AI_ENDPOINT` into `FocelleAIEndpoint`
- `FOCELLE_AI_SHARED_TOKEN` into `FocelleAISharedToken`

`Focelle/App/FocelleAPI.swift` rejects cloud calls unless both are valid and the
endpoint is HTTPS.

Important:

- `.github/workflows/testflight.yml` validates and injects
  `FOCELLE_AI_ENDPOINT` and `FOCELLE_AI_SHARED_TOKEN`.
- `.github/workflows/ios.yml` currently builds the unsigned device IPA without
  those values.
- Therefore run-52's installed IPA cannot use cloud Gemini even if the Worker
  is deployed. On-device guidance should still work offline.

After Worker deployment, either:

- add a secure manual beta-device build workflow that injects those secrets
  without publishing them in artifacts/logs, or
- wait for the signed TestFlight workflow after Apple Developer signing is
  available.

Never commit the shared token to make the public unsigned IPA convenient.

## Implemented surface already present

Inspect before rewriting. The repository already contains:

- AVFoundation preview/capture, front/rear, Photos save, permission/failure
  states, orientation, aspect ratios, zoom, focus/exposure, flash, timer,
  24/48 MP handling.
- Twelve owned Core Image filter recipes, live editor, intensity, compare,
  reset, custom presets.
- Offline preset store plus CloudKit sync code.
- Existing-photo picker/editor/save-new-copy flow.
- Vision scene measurements, tracking/stabilization, subject selection,
  guidance overlay, voice, and guarded Auto Capture state.
- Strict three-plan AI schema/client/state machine.
- Worker authentication, validation, metadata stripping, rate limiting, quota
  reserve/commit/refund.
- Settings, localization, privacy controls, anonymous analytics.
- Remote Beta Pro, quota/reward state, StoreKit, Sign in with Apple,
  deletion-retention logic, and referral behind disabled flags.
- Privacy manifest, App Store/privacy drafts, icon, TestFlight workflow, and
  physical checklist.

Key files are listed in `docs/completion-audit.md`; source files live under:

- `Focelle/Camera/`
- `Focelle/Filters/`
- `Focelle/AI/`
- `Focelle/Commerce/`
- `Focelle/App/`
- `backend/src/`
- `backend/test/`
- `FocelleTests/SmokeTests.swift`

`docs/focelle-plan.md` still shows many unchecked boxes even though code exists.
Do not mechanically mark them complete. Update only after current evidence
proves each acceptance criterion.

## Known automated evidence and limits

Backend pre-handoff:

- 30 tests across 6 files pass after the auth fix.
- TypeScript/type generation passes.
- Worker dry-run passes.

iOS latest remote evidence:

- Run 52 passed all CI steps on the iPhone 17e simulator.
- Previous audit recorded 27 Swift tests; inspect run-52 xcresult/logs if exact
  current count is needed.
- Simulator launch only proved onboarding, not camera hardware.

Physical evidence:

- IPA installation passed.
- App launch currently fails.
- No camera, Photos, filter, AI, CloudKit, StoreKit, rewarded ad, accessibility,
  or ten-minute performance item has passed on the real device yet.

## External gates that remain

- Physical crash log and iPhone 17e checklist.
- Working Gemini API key and generated app shared token.
- Worker deployment and smoke tests.
- GitHub Actions secrets for cloud-enabled signed builds.
- Paid Apple Developer/App Store Connect membership and signing material for
  TestFlight.
- Apple App ID/provisioning capabilities:
  - Sign in with Apple.
  - CloudKit container `iCloud.com.pnhd.focelle`.
- Second iCloud-capable device/session before claiming real cross-device sync.
- AdMob account/test mode and consent check.
- StoreKit/App Store sandbox products and transaction checks.
- Seller/support/privacy URLs and final trademark review.
- Explicit authorization immediately before TestFlight upload, App Store
  submission, real ad enablement, or real financial action.

## Immediate continuation order

1. `git status`, inspect the two-line backend security diff and this handoff.
2. Commit/push the verified auth fix and handoff if not already checkpointed.
3. Check the triggered GitHub Actions run and repair it until green.
4. Reconnect the iPhone and collect the launch crash report.
5. Reproduce the crash from the log with the smallest focused test.
6. Fix the root cause without removing required signed-build capabilities.
7. Run backend tests/typecheck/dry-run and macOS iOS CI.
8. Download the new unsigned IPA, re-sign with Sideloadly, and retest launch.
9. Run the physical checklist incrementally:
   - onboarding and permissions;
   - preview and front/rear;
   - portrait/landscape capture/save/orientation;
   - aspect ratio, zoom, tap focus/exposure, flash, timer, 24/48 MP;
   - twelve filters, compare, intensity, custom preset persistence;
   - existing-photo edit/save;
   - offline guidance, subject selection, voice, Auto Capture;
   - failure/background/interruption and ten-minute session.
10. Deploy/smoke-test Worker only after secure secrets are available.
11. Build a cloud-enabled signed beta and evaluate one tap on consented scenes.
12. Finish the remaining sandbox/two-device/accessibility evidence.
13. Update `docs/focelle-plan.md` and `docs/completion-audit.md` from fresh
    evidence, not intent.

## Commands

From the worktree root:

```powershell
git status --short --branch
git diff --check
git log -8 --oneline --decorate

npm --prefix backend test
npm --prefix backend run typecheck

Push-Location backend
npm exec -- wrangler deploy --dry-run
npm exec -- wrangler whoami
Pop-Location
```

Do not run iOS compile commands locally on Windows. Push to the branch and use
the `iOS` GitHub Actions workflow. Verify the exact commit SHA in the successful
run before relying on it.

## Final definition of done

Use the eleven success criteria in `docs/focelle-spec.md`. Completion requires:

- fresh automated evidence for each testable requirement;
- physical iPhone 17e evidence for camera/editor/guidance/performance;
- two-device evidence for iCloud;
- deployed cloud evidence for Gemini and remote beta/quota behavior;
- Apple/AdMob/StoreKit sandbox evidence for gated commerce paths;
- repository secret/personal-file scan;
- no enabled production monetization or public submission without approval.

Until then, leave the goal active and report the exact remaining external gates.
