# Focelle iOS — Agent Handoff

Updated: 2026-08-11 (task FCL-M2-R1)

Read `docs/project-status.md` for the full status matrix and
`docs/AI_WORKFLOW.md` for the multi-agent workflow authority (roles, review
policy, evidence levels, task-lifecycle rules). This file is the short
operational handoff: where you are, what is proven, what not to break.

## Identity

- Repository: `PNHD/focelle-ios` (`https://github.com/PNHD/focelle-ios.git`)
- Protected product worktree (absolute) — do not edit, switch, clean, reset,
  stage, or commit in this from any other session:
  `C:\Users\phamn\Documents\Codex\2026-07-22\build-1-app-ch-p-h\.worktrees\focelle-beta`
- Integration branch: `feat/focelle-beta`, integration SHA
  `82c94c09a70a8533dc44bc2655e97d9c59b4b354` (`docs: record camera core
  physical pass`)
- Current task branch: `task/FCL-M2-R1-capture-save-privacy`, CI-tested
  implementation HEAD `788f41301b074f13e9319e1c6eab8e4a44dad52d`
- Current pull request: draft PR #5, targets `feat/focelle-beta`, **not
  merged**. Batch A remains on `task/FCL-M2-batch-a-local-coach`, HEAD
  `dbe9996431e988345f9914c8b6fac76a7848f5d6`, draft PR #3, **not merged**.
- `D:\Focelle` is not a repository and must never be used for this project.

## FCL-M2 Batch A — current verdict

**`FCL-M2 Batch A — PHYSICAL FAIL; recovery audit required.`**

Two separate, non-contradictory facts:

- **CI VERIFIED**: GitHub Actions run `30703230859` passed at
  `dbe9996431e988345f9914c8b6fac76a7848f5d6` — `backend`, Swift format lint,
  simulator build, 93 XCTest tests (zero failures), `device-package`. This is
  CI success, not product acceptance.
- **USER-OBSERVED FAILURE** on iPhone 17e (physical device): capture appeared
  to complete but no new asset was visible in Photos; broad Photo Library
  access was requested at launch; the resolution UI showed 12 MP and 48 MP
  but not 24 MP, and resolution selection sometimes appeared ineffective or
  unclear; Coach Creative appeared to mainly change zoom to roughly 2x with
  no apparent pose/composition improvement; the Coach popup obscured the
  preview and stayed open after selection or Apply; a person/child scene
  received product-oriented coaching text; a "no suitable plan" message could
  coexist with plans or an Apply control. Overall Coach UI/UX was judged
  unacceptable relative to the intended product value.

These are user-observed physical symptoms, not diagnosed root causes. Root
cause is **not established**. Do not infer a source-level cause from this
list without investigation.

## FCL-M2-R1 — Capture, Save, and Privacy Reliability

**`FCL-M2-R1 — CI VERIFIED; physical validation pending.`** The scoped
capture/save/privacy repair is implemented at
`788f41301b074f13e9319e1c6eab8e4a44dad52d`. GitHub Actions run
`31451486572` passed at that exact SHA: `backend`, `simulator-test` (including
Swift format lint and XCTest), and `device-package` — 3/3 success. This is CI
evidence only; no real-device Photos or permission observation was performed.

The implementation keeps Photo Library access add-only and requests it only
on an explicit save; capture completion is correlated by the actual callback
identifier and guarded for exactly-once terminal handling. It does not read,
enumerate, observe, or otherwise broad-access the photo library. This task
does not change the unresolved Batch A Coach finding or start Batch B.

## Next product action

The next required evidence for FCL-M2-R1 is the human physical checklist on
an iPhone: permission timing, save visibility in Photos, rapid/repeated
capture behavior, lifecycle interruption, and user-facing error copy. These
checks are **PENDING**. Do not represent the CI result as product acceptance.

Do not merge PR #3 or PR #5. Do not start Batch B — it is **NOT STARTED**.

iPhone 12 Pro physical validation has **NOT RUN** at any commit referenced in
this handoff.

## Safety warnings

- There is one old stash (`stash@{0}: On main: move camera controls to
  focelle-beta worktree`) at the root `main` checkout. Do **not** apply, pop,
  or drop it.
- `.analysis/` at the `main` checkout is local untracked data. Never stage
  it.
- Never run `git add -A`. Stage explicit paths only.
- Never treat simulator or CI success as physical or product evidence.
- Do not merge PR #3. Do not push directly to `feat/focelle-beta`; use a
  `task/…` branch.
- Do not enable real charges, production ads, referral, TestFlight upload, or
  App Store submission without explicit user authorization at the action
  point.
- Never place provider keys, Apple credentials, certificates, provisioning
  profiles, or tokens in source, logs, or docs.

## Product constraints that still bind

- Communicate with the user in Vietnamese; the user is not a programmer.
- Target device: iPhone 17e, iOS 26.x, with iPhone 12 Pro as a compatibility
  target. The user is on Windows with no Mac — all iOS builds go through
  GitHub Actions macOS runners. Do not attempt local iOS compilation.
- The camera must stay usable with no login, cloud, ads, quota, or purchases.
- Continuous realtime geometry stays on-device; the cloud model is only for a
  user-triggered semantic analysis.
- Filters are owned numeric recipes. Do not import unlicensed LUTs.

## Document authority

- `docs/AI_WORKFLOW.md` — **canonical multi-agent workflow.** Roles, review
  policy, evidence levels, task-lifecycle, worktree rules.
- `docs/project-status.md` — **current project status.** Start here.
- `docs/focelle-spec.md` — source of truth for **scope**, not status.
- `docs/focelle-plan.md` — historical implementation plan. Its checkboxes do
  not reflect HEAD.
- `docs/completion-audit.md` — historical audit dated 2026-07-26, written
  against run `30210673032`. Superseded; not current proof.

## Commands

From a worktree root:

```powershell
git status --short --branch
git rev-parse HEAD
git log -8 --oneline --decorate

npm --prefix backend test
npm --prefix backend run typecheck
```

Do not run iOS build commands locally. Push a task branch and read the `iOS`
workflow result, verifying the exact SHA in the run before relying on it.
