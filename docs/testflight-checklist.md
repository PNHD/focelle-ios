# Focelle TestFlight Checklist

## Required before a signed upload

- [ ] Active Apple Developer Program membership and App Store Connect app record.
- [ ] Seller/legal name, public support email, Support URL, and Privacy Policy URL supplied.
- [ ] Distribution certificate, App Store provisioning profile for `com.pnhd.focelle`, Team ID, and App Store Connect API key stored only as CI secrets.
- [ ] App ID and provisioning profile enable Sign in with Apple and CloudKit container `iCloud.com.pnhd.focelle`.
- [ ] Gemini API key and a generated app shared token stored as Cloudflare secrets.
- [ ] Worker deployed; production iOS build receives its HTTPS endpoint and shared token from CI secrets.
- [ ] App Store product IDs match the four product IDs in `StoreKit.storekit`; sandbox flag remains off until sandbox verification is ready.
- [ ] Beta Pro is enabled; production ads, paid products, accounts, and referrals remain server-disabled.
- [ ] Public privacy policy matches the final Xcode privacy report and current Google Mobile Ads disclosure.
- [ ] Separate internal-test authorization given before any TestFlight upload.

## Fresh install on iPhone 17e / iOS 26

- [ ] App icon and launch screen render correctly; camera opens without login.
- [ ] Deny camera, recover in Settings, then capture with rear and front camera.
- [ ] Portrait and both landscape orientations save correctly at 4:3, 1:1, and 16:9.
- [ ] Test tap focus, exposure, 1x–supported zoom, flash off/auto/on, 3s/10s timer, grid, and volume shutter.
- [ ] Compare supported 24 MP default and 48 MP opt-in files; confirm no missing or corrupted save.
- [ ] Apply all 12 Focelle Originals; compare preview/export and original-preservation fallback.
- [ ] Create, rename, favorite, edit, delete, restart, and offline-check a custom preset.
- [ ] Pick one existing photo, compare, edit, save a copy, and confirm the original was untouched.
- [ ] Test person, couple, group, and no-subject on-device guidance; manual shutter always works.
- [ ] Test AI primary/Safe/Creative plans, cancel, airplane mode, timeout, provider failure, and On-device only mode.
- [ ] Test voice and Auto Capture off by default; movement/subject loss/manual shutter cancels Auto Capture.
- [ ] Background/foreground, incoming call/camera interruption, network switch, and low-memory warning leave the camera recoverable.
- [ ] Run continuously for 10 minutes while recording thermal state, memory peak, preview stalls, capture/save failures, and AI median/P95 latency.
- [ ] Check VoiceOver, largest Dynamic Type, Reduce Motion, contrast, and guidance without relying on color.
- [ ] With a second device, verify private iCloud preset convergence.

## Commerce sandbox, still hidden from beta users

- [ ] Monthly/yearly purchase, cancel/expire, revoke, restore, and offline cached entitlement.
- [ ] Sign in with Apple only at credit sync/purchase; 30/100-credit purchases converge without duplicate grant.
- [ ] Account deletion removes the server account link.
- [ ] Referral self/duplicate block, first verified purchase reward, refund, and revocation.
- [ ] Configure Google's privacy message before requesting any ad; expose privacy options when required.
- [ ] Use only Google test rewarded ad ID; verify load/show/reward failure, duplicate callback, +3 AI/+5 filter reward, and five-ad daily cap.

## Evidence to attach

- [ ] GitHub Actions URL and passing backend/iOS logs.
- [ ] Xcode privacy report and archive validation log.
- [ ] Ten-minute device log with model, OS, 24/48 MP file dimensions, thermal/memory observations, and latency table.
- [ ] Short screen recording of onboarding, camera, AI, filter editor, existing-photo editor, and failure recovery.
- [ ] Tester feedback and all release-blocking issues resolved or explicitly accepted.
