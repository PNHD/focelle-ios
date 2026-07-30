# Focelle iOS — Agent Handoff

Updated: 2026-07-30 (task FCL-001B)

Read `docs/project-status.md` for the full status matrix. This file is the
short operational handoff: where you are, what is proven, what not to break.

## Identity

- Repository: `PNHD/focelle-ios` (`https://github.com/PNHD/focelle-ios.git`)
- Correct worktree (absolute):
  `C:\Users\phamn\Documents\Codex\2026-07-22\build-1-app-ch-p-h\.worktrees\focelle-beta`
- Integration branch: `feat/focelle-beta` (tracks `origin/feat/focelle-beta`)
- Current task branch: `task/FCL-001B-project-status`
- Baseline commit: `5532063cfe03bb3de65220c3e95b50265273b709`
  (`fix: recolour the last target frame shadow`)
- Pull request: <https://github.com/PNHD/focelle-ios/pull/1> (draft, do not merge)
- CI baseline: workflow `iOS`, run number 64, run ID `30368976476`,
  conclusion success, jobs `backend` + `simulator-test` + `device-package`
  all success.

Provenance note on CI: the run-64 numbers above were recorded by the FCL-001A
audit. `gh` is **not authenticated** in the current session, so this session
could not re-query the Actions API. Before downloading or installing the run-64
IPA, confirm that run 64's head SHA is exactly `5532063…`.

## Critical directory warning

- `D:\Focelle` is **not** a repository. It is not a checkout, not a worktree,
  and not a mirror of this project.
- Never create source, docs, or task output at `D:\Focelle`.
- Never run a beta task from the root `main` checkout
  (`…\build-1-app-ch-p-h`). That checkout is a separate worktree on `main`
  and does not contain this branch's work.
- Always confirm `git rev-parse --show-toplevel` before editing.

## Current evidence

Use these four levels; do not blur them.

- **CI verified** — proven by a green GitHub Actions run on a known SHA.
  Covers: backend unit tests, Swift lint, iPhone 17e *simulator* build/test,
  simulator onboarding launch, unsigned device IPA packaging.
- **Physical device verified** — proven by observation on the real iPhone 17e.
  At HEAD `5532063` there is **nothing** at this level.
- **Not physically verified** — everything the app does on real hardware:
  launch, camera preview, shutter, photo saving, filters, guidance,
  on-device Vision, CloudKit, StoreKit, ads.
- **Blocked by external credentials or infrastructure** — Cloudflare Worker
  deployment, Apple Developer signing/TestFlight, CloudKit production
  container, StoreKit sandbox, AdMob, second iCloud device.

Simulator success is **not** physical evidence. Code presence is **not**
evidence of anything.

## Known physical history

Two crashes were observed on the real iPhone earlier in the project, each with
a crash report, and each patched:

1. **CloudKit launch crash.** The app exited immediately at launch on the
   sideloaded build. Patched by `1e81b2a`
   (`fix: skip CloudKit when the container is unset`) — touches
   `Focelle/Filters/PresetSync.swift`, `PresetStore.swift`, `Info.plist`,
   `.github/workflows/testflight.yml`, plus a regression test.
2. **Shutter crash.** The app crashed on capture. Patched by `8712f04`
   (`fix: keep photo settings inside what the output allows`) — touches
   `Focelle/Camera/CameraSession.swift` plus a regression test.

Both commits are ancestors of HEAD (verified with `git merge-base
--is-ancestor`). **Neither patch has been re-verified on a physical device at
the current HEAD.** There is no evidence that the app launches successfully on
the iPhone at `5532063`, and no evidence that any photo has been captured or
saved to Photos on the device. Do not write or imply otherwise.

## Current gate

`FCL-001B — Baseline Documentation Rebuild` is still on task branch
`task/FCL-001B-project-status`, currently in review/revision. This is the
state as of this document commit — it is not a permanent instruction for
every future session. Check the actual branch/PR state before trusting it.

**Stop condition:** if you are on `task/FCL-001B-project-status` and about to
run a device smoke test, stop. FCL-002 must not run on the documentation
branch.

### Once FCL-001B is approved and merged

- `task/FCL-001B-project-status` must **not** be reused for FCL-002.
- The next session must open or update `feat/focelle-beta` and verify the
  **current** integration HEAD — do not assume it is still `5532063`; the
  merge itself moves it.
- Before running FCL-002, there must be a status-transition commit that marks
  FCL-001B complete and records the new integration SHA.
- Only then create a new branch from the verified integration HEAD, named
  `task/FCL-002-physical-smoke`.
- FCL-002 is not Active until that branch/task contract actually starts. It
  is the next gate, not a started one.

FCL-002 target when it starts: the artifact of CI run 64, after confirming
that run's head SHA matches the integration HEAD in force at that time.

## Safety warnings

- There is one old stash (`stash@{0}: On main: move camera controls to
  focelle-beta worktree`). Do **not** apply, pop, or drop it.
- `.analysis/` at the `main` checkout is local untracked data. Never stage it.
- Never run `git add -A`, especially from the `main` checkout. Stage explicit
  paths only.
- Never treat the simulator as physical evidence.
- Do not resume feature implementation before the physical smoke checkpoint
  passes, unless the PM issues a new task contract that reorders the work.
- Do not merge PR #1. Do not push directly to `feat/focelle-beta`; use a
  `task/…` branch.
- Do not enable real charges, production ads, referral, TestFlight upload, or
  App Store submission without explicit user authorization at the action point.
- Never place provider keys, Apple credentials, certificates, provisioning
  profiles, or tokens in source, logs, or docs.

## Product constraints that still bind

- Communicate with the user in Vietnamese; the user is not a programmer.
- Target device: iPhone 17e, iOS 26.x. The user is on Windows with no Mac —
  all iOS builds go through GitHub Actions macOS runners. Do not attempt local
  iOS compilation.
- The camera must stay usable with no login, cloud, ads, quota, or purchases.
- Continuous realtime geometry stays on-device; the cloud model is only for a
  user-triggered semantic analysis.
- Filters are owned numeric recipes. Do not import unlicensed LUTs.

## Document authority

- `docs/project-status.md` — **current project status.** Start here.
- `docs/focelle-spec.md` — source of truth for **scope**, not status.
- `docs/focelle-plan.md` — historical implementation plan. Its checkboxes do
  not reflect HEAD.
- `docs/completion-audit.md` — historical audit dated 2026-07-26, written
  against run `30210673032`. Superseded; not current proof.

## Commands

From the worktree root:

```powershell
git status --short --branch
git rev-parse HEAD
git log -8 --oneline --decorate

npm --prefix backend test
npm --prefix backend run typecheck
```

Do not run iOS build commands locally. Push a task branch and read the `iOS`
workflow result, verifying the exact SHA in the run before relying on it.
