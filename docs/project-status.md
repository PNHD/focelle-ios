# Focelle Project Status

Baseline B0 — established 2026-07-30 by task FCL-001B.

## 1. Status authority

- **This file is the current source of project status.** Read it before
  planning or claiming progress.
- `docs/focelle-spec.md` is the source of truth for **scope**. It defines what
  the product must do. It says nothing about what currently works.
- `docs/focelle-plan.md` is a **historical implementation plan**. Its
  checkboxes were never reconciled against HEAD and must not be read as status.
- `docs/completion-audit.md` is a **historical audit** dated 2026-07-26,
  written against GitHub Actions run `30210673032`. It no longer reflects HEAD
  and is not current proof.
- `.ai/SESSION.md` is the short operational handoff for the next agent.

Neither `focelle-plan.md` nor `completion-audit.md` was modified by FCL-001B.
They are left intact as history.

## 2. Baseline B0

| Field | Value |
|---|---|
| Baseline date | 2026-07-30 |
| Repository | `PNHD/focelle-ios` |
| Worktree | `C:\Users\phamn\Documents\Codex\2026-07-22\build-1-app-ch-p-h\.worktrees\focelle-beta` |
| Integration branch | `feat/focelle-beta` |
| Baseline commit | `5532063cfe03bb3de65220c3e95b50265273b709` |
| Commit subject | `fix: recolour the last target frame shadow` |
| Pull request | [#1](https://github.com/PNHD/focelle-ios/pull/1) — draft, not merged |
| CI run | workflow `iOS`, run number 64, run ID `30368976476`, conclusion success |
| CI jobs | `backend`, `simulator-test`, `device-package` — 3/3 success |
| Working-tree observation | Recorded clean by the read-only FCL-001A audit; historical local-state evidence, not reconstructible from the commit alone |
| Highest evidence level | CI VERIFIED |
| Physical device evidence | none at this commit |

`D:\Focelle` is not a repository and must never be used for this project.

**CI provenance caveat.** The run-64 figures were recorded by the FCL-001A
audit. The `gh` CLI is unauthenticated in the FCL-001B session, so run 64 could
not be re-queried here. Before relying on the run-64 IPA, confirm that run 64's
head SHA equals `5532063cfe03bb3de65220c3e95b50265273b709`.

## 3. Evidence levels

| Level | Meaning |
|---|---|
| `NOT FOUND` | No implementation exists in the repository. |
| `CODE EXISTS` | Source is present and compiles. Nothing more is claimed. |
| `AUTOMATED TESTED` | Covered by a unit or integration test that passes locally. |
| `CI VERIFIED` | Proven by a green GitHub Actions run on a known commit SHA. |
| `PHYSICAL DEVICE VERIFIED` | Observed working on the real iPhone 17e, with the observation recorded. |
| `BLOCKED` | Cannot be advanced without external credentials, hardware, or infrastructure. |
| `UNKNOWN` | Not assessed against the current HEAD. |

**Code existing does not mean the feature works.** A module at `CODE EXISTS`
or even `CI VERIFIED` may still fail on real hardware. Simulator results never
count as physical evidence.

## 4. Current module matrix

Status as of `5532063`. Conservative by rule: when in doubt, the lower level wins.

| Module | Highest evidence | Blocker / uncertainty | Next evidence required |
|---|---|---|---|
| iOS app launch | CI VERIFIED (simulator onboarding launch) | Launch crash was patched by `1e81b2a`; never re-checked on device at this HEAD | Physical launch on iPhone 17e without immediate exit |
| Camera capture | CI VERIFIED (builds, unit tests) | Shutter crash was patched by `8712f04`; the fix is not physically verified | One successful physical shutter press with no crash |
| Camera controls | CODE EXISTS | Front/rear, aspect, zoom, focus/exposure, flash, timer, 24/48 MP exercised only in build/tests | Physical interaction pass over each control |
| Photo saving | CODE EXISTS | **No evidence any photo has ever been saved to Photos on a device** | A captured photo confirmed present in the iPhone Photos library |
| Filters / thumbnails | CI VERIFIED (build + tests) | Twelve owned recipes and live preview untested on real frames | Physical render/compare/intensity check on device output |
| Presets | CI VERIFIED (local store tests) | Local persistence only; sync path is separate | Physical create/edit/persist across app relaunch |
| Guidance | CODE EXISTS | Overlay, arrows, debounce, voice, Auto Capture unvalidated in real scenes | Physical walk-through for stability, flicker, occlusion |
| On-device Vision | CODE EXISTS | Scene measurement/tracking/stabilization not exercised on real camera input | Physical scene-tracking observation |
| Cloud AI | CI VERIFIED at schema/client/backend unit level | Worker not deployed; the run-64 IPA carries no endpoint or token, so no end-to-end path exists | Deployed Worker plus one consented end-to-end analysis returning three plans |
| CloudKit | CI VERIFIED on the **disabled** path only | Real sync BLOCKED — needs signed provisioning for `iCloud.com.pnhd.focelle` and a second device | Two-device convergence on a signed build |
| Backend | AUTOMATED TESTED + CI VERIFIED (`backend` job green) | Not deployed; remote behaviour unproven | `/health`, authenticated `/v1/config`, and `/v1/analyze` smoke tests against the deployed Worker |
| Authentication | CODE EXISTS, behind a disabled flag | Sign in with Apple capability not provisioned; `APP_APPLE_ID` empty | Signed build with the capability enabled, then a real sign-in |
| Quota / commerce | CI VERIFIED at backend unit level, flags off | StoreKit sandbox, AdMob test mode, referral all BLOCKED on external accounts | Sandbox purchase, test rewarded ad, and refund/credit behaviour on device |
| Onboarding / settings | CI VERIFIED (simulator onboarding screenshot) | Settings and privacy controls not exercised on device | Physical fresh-install onboarding and settings pass |
| Accessibility | UNKNOWN | Not assessed against HEAD; no automated a11y check in CI | VoiceOver, Dynamic Type, and contrast pass on device |
| Localization | CODE EXISTS (`Localizable.xcstrings`, vi + en) | Coverage and truncation unverified in the running UI | Physical pass in both languages checking for missing keys and clipped text |
| CI | CI VERIFIED | None outstanding at baseline | Keep run number and SHA recorded on each status update |
| Signing / TestFlight | CI VERIFIED for the **unsigned** IPA only | TestFlight BLOCKED — no Apple Developer signing material available | Signed archive produced by `testflight.yml`, then an authorized upload |

## 5. Task status

- **`FCL-001B — Baseline Documentation Rebuild`**: `INTEGRATED LOCALLY —
  REVIEW PASSED`. Independent Codex review passed on commit `eac6bd2`. All
  three FCL-001B commits (`45b1868`, `74b1109`, `eac6bd2`) were fast-forwarded
  into the local `feat/focelle-beta` integration branch. Not pushed to
  `origin` in this task.
- **`FCL-001C — Integrate Baseline Documentation and Establish Transition
  State`**: `IN REVIEW`. Branch: `task/FCL-001C-status-transition`, based on
  the integrated FCL-001B head. Outcome: record the FCL-001B integration,
  the artifact provenance, and the artifact reuse decision below, and put
  FCL-002 at Next Gate without activating it.
- **`FCL-002 — Physical Launch and Capture Smoke Check`**: `NEXT GATE — NOT
  ACTIVE`. No branch has been created for it yet.

### FCL-001C transition record

| Field | Value |
|---|---|
| Integrated FCL-001B head | `eac6bd2e1a3469d1976d76d5be1b6f17233694fd` |
| Device artifact source SHA | `5532063cfe03bb3de65220c3e95b50265273b709` |
| Device artifact run | run number `64`, run ID `30368976476` |
| Artifact names | `focelle-ios-ipa`, `focelle-ios-tests` |
| Artifact reuse decision | `ALLOWED` — every path changed between `5532063` and this transition branch is documentation/project-control (`.ai/SESSION.md`, `docs/project-status.md`) |
| Artifact reuse evidence | exact changed paths: `.ai/SESSION.md`, `docs/project-status.md` |
| Transition commit | resolve with `git rev-parse HEAD` after this commit is created — not hardcoded here |
| FCL-002 branch base | the actual `feat/focelle-beta` HEAD after this FCL-001C transition commit is reviewed and fast-forwarded into integration — read Git directly, do not assume a SHA from this document |

The device artifact (run 64) was built from `5532063` and is **not** an
artifact of `eac6bd2` or of this transition commit. It stays attributed to
`5532063` regardless of later documentation-only commits.

## 6. Next gate

**`FCL-002 — Physical Launch and Capture Smoke Check`** — `NEXT GATE — NOT
ACTIVE`.

Before starting FCL-002, the agent must:

1. Wait for `FCL-001C` to be reviewed PASS.
2. Wait for `FCL-001C` to be fast-forwarded into `feat/focelle-beta`.
3. Open or update the integration branch and read the actual integration
   HEAD from Git — do not trust a hardcoded SHA from this document.
4. Re-verify the artifact reuse decision above against the actual diff from
   `5532063` to the current integration HEAD. If the decision is no longer
   `ALLOWED` — any changed path touches an executable/build-input location —
   stop here: do not create the FCL-002 branch, and wait for a fresh CI
   artifact built from the current integration HEAD before proceeding.
5. Only if the reuse decision is confirmed `ALLOWED`, create
   `task/FCL-002-physical-smoke` from that exact verified integration HEAD.
6. Only then install the run-64 IPA and run the physical smoke check: that
   the app launches without exiting, that the camera preview appears, that
   the shutter does not crash, and that a captured photo reaches the Photos
   library.

If the agent is currently on `task/FCL-001B-project-status` or
`task/FCL-001C-status-transition`, it must stop — FCL-002 does not run on a
documentation branch.

No feature backlog is scheduled behind this gate yet. The gate result decides
what comes next.

## 7. External blockers

These are unverified or unavailable to the current session. None is asserted
to be permanently absent — where the audit simply could not reach it, it is
recorded as unverified.

| Blocker | Current state |
|---|---|
| Cloudflare Worker deployment and secrets | Worker `focelle-api` was reported not found on a previous check; `APP_SHARED_TOKEN` and `GEMINI_API_KEY` are not available to the current session |
| Apple Developer / TestFlight credentials | Not available to the current session; membership and signing material unverified |
| CloudKit production provisioning | Container `iCloud.com.pnhd.focelle` not confirmed present in the App ID or provisioning profile |
| StoreKit sandbox | Sandbox products and transaction behaviour unverified |
| AdMob integration | Account, test mode, and consent flow unverified |
| Second device for sync | No second iCloud-capable device confirmed available |
| GitHub API access | `gh` CLI unauthenticated in this session; Actions state could not be re-queried directly |

## 8. Update protocol

1. Update this file only when there is a new commit, a new CI result, new
   device evidence, or a change in an external blocker.
2. Every claim must point to concrete evidence: a commit SHA, a CI run ID, a
   named artifact, a crash report, or a recorded device observation.
3. Never record a module as done, complete, or working on the strength of code
   presence alone.
4. A task may only update the rows that its own scope covered. Leave every
   other row untouched, including rows you believe are stale — flag them
   instead.
5. Downgrade freely. If evidence for a row cannot be located, move it to
   `UNKNOWN` rather than carrying an unsupported level forward.
