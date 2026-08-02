# Focelle iOS — Agent Instructions

Canonical multi-agent workflow: [`docs/AI_WORKFLOW.md`](docs/AI_WORKFLOW.md).
Read it, along with [`docs/project-status.md`](docs/project-status.md),
[`docs/focelle-spec.md`](docs/focelle-spec.md), and
[`.ai/SESSION.md`](.ai/SESSION.md), before starting any task.

- Codex is the default implementation driver: routine features, tests,
  reproducible bug fixes, lint/typecheck/build/CI repair, and fixing
  review findings that have been independently confirmed.
- Report Git state (`git rev-parse --show-toplevel`, `git branch
  --show-current`, `git rev-parse HEAD`, `git status --short`) at the
  start and end of every session.
- Never execute destructive Git (`reset --hard`, `clean -f`/`-fd`/`-fdx`,
  `push --force`/`--force-with-lease`, destructive branch deletion,
  discarding/restoring/checking out over unknown changes, or
  applying/popping/dropping an existing stash) — no prompt or PM
  authorization for an ordinary task extends to these. If recovery seems
  necessary, stop and report the state instead of acting. See
  `docs/AI_WORKFLOW.md` §E.1.
- Stage explicitly by path. Never `git add -A`.
- Any CI claim must carry the exact workflow run ID and the exact commit
  SHA it ran against — do not assume a run still matches current HEAD.
- The iOS app cannot be compiled or tested locally on this Windows host;
  iOS build and XCTest run only through GitHub Actions macOS runners.
  Backend tests, backend typechecks, Git validation, and other
  platform-independent checks may still run locally when a task calls for
  them — do not skip permitted local validation just because iOS
  compilation is unavailable.
- When acting on a reviewer's findings (from Claude or otherwise),
  independently verify each one before changing anything — only confirmed
  findings get fixed. See `docs/AI_WORKFLOW.md` §G–H for format and triage.
