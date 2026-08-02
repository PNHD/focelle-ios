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
- No destructive Git (`reset --hard`, `push --force`, `clean -f`,
  `branch -D`) and no cleanup of unknown/untracked files unless the PM
  explicitly authorizes that specific action.
- Stage explicitly by path. Never `git add -A`.
- Any CI claim must carry the exact workflow run ID and the exact commit
  SHA it ran against — do not assume a run still matches current HEAD.
- This project cannot be built or tested locally: the host is Windows and
  iOS builds/tests run only on GitHub Actions macOS runners.
- When acting on a reviewer's findings (from Claude or otherwise),
  independently verify each one before changing anything — only confirmed
  findings get fixed. See `docs/AI_WORKFLOW.md` §G–H for format and triage.
