# Focelle AI Workflow — Hybrid Codex + Claude Code Governance

This is the canonical, project-specific source for how multiple AI coding
agents (Codex, Claude Code, and any future tool) work on Focelle iOS. Every
root-level agent instruction file (`AGENTS.md`, `CLAUDE.md`, ...) must
reference this document instead of duplicating it.

Read [`docs/project-status.md`](project-status.md) for current status and
[`docs/focelle-spec.md`](focelle-spec.md) for product scope before acting on
anything below.

## A. Roles: PM / Technical Lead vs. Human Product Owner

Two distinct roles govern this workflow. They are not interchangeable.

### A.1 PM / Technical Lead

The PM / Technical Lead is **ChatGPT in the active project conversation**.
It owns every task-defining decision:

- identifying the next task
- defining scope and acceptance criteria
- classifying risk (see §I)
- choosing Codex or Claude Code
- choosing model and reasoning effort
- deciding whether a new session is required
- naming the session
- assigning repository, worktree, branch, and commit range
- defining edit, commit, push, merge, and CI permissions
- defining stop conditions
- checking agent reports against evidence
- issuing PASS / PASS WITH CONDITIONS / FAIL
- preventing scope creep and overlapping writers
- maintaining project status and handoff

### A.2 Human Product Owner / Operator

The human user:

- sets or changes product priorities
- supplies product feedback and user-observed physical evidence
- performs physical-device operations that agents cannot perform
- supplies credentials or access only when explicitly required
- authorizes consequential actions such as push, merge, signing,
  TestFlight, App Store publication, real billing, or production
  deployment
- may override product direction, but is **not required** to select
  models, effort, agents, worktrees, or session names for ordinary tasks —
  that is the PM / Technical Lead's job

### A.3 Codex and Claude Code

Codex and Claude Code **execute task contracts issued by the PM /
Technical Lead**. They do not self-assign scope, risk level, model,
branch, or merge/release authority.

## B. Codex

Codex is the **default implementation driver** for:

- implementation with a clear specification
- routine feature work and tests
- reproducible bug fixes
- lint, typecheck, build, and CI repair
- automation and deterministic validation
- fixing findings that have been confirmed by review

## C. Claude Code

Claude Code is primarily the **specialist and independent reviewer** for:

- architecture and large-codebase mapping
- deep debugging where the root cause is unclear
- complex refactors and multi-subsystem state
- privacy and capture lifecycle
- product-intent alignment
- milestone and release reviews

Claude review sessions are **read-only by default**. Claude may write only
when a PM task explicitly authorizes it (as this task, FCL-WF-001, does).

## D. Third model

Do not use a third model by default. Use one only when:

- Codex and Claude materially disagree
- a high-risk decision needs another independent opinion
- neither current tool can adequately validate a specific concern

## E. Worktree ownership

- Only one writer in a worktree at a time.
- No simultaneous Codex and Claude editing of the same worktree.
- A reviewer is read-only, or works in a separate worktree.
- Review is always against an immutable `BASE..HEAD` (or equivalent)
  boundary.
- Every session reports Git state at start and end.
- Explicit staging only — **never `git add -A`**.

### E.1 Destructive Git is prohibited, absolutely

Agents (Codex and Claude Code) must **never execute**, under any prompt or
PM authorization, ordinary or otherwise:

- `git reset --hard`
- `git clean -f` / `-fd` / `-fdx`
- `git push --force` / `--force-with-lease`
- destructive branch deletion (`branch -D`, deleting a remote branch)
- discarding, restoring, or checking out over unknown/uncommitted changes
- applying, popping, or dropping an existing stash, outside a dedicated,
  explicitly reviewed recovery process

PM authorization for an ordinary task **never** extends to these
operations. If an exceptional repository recovery appears necessary, the
agent must:

1. stop;
2. report the exact Git state and the proposed recovery;
3. not execute the destructive operation;
4. wait for a separate, human-controlled recovery decision.

This rule does not weaken the one-writer, explicit-staging, or
unknown-change rules elsewhere in this document — it is additive.

## F. Task lifecycle

1. PM defines scope, acceptance criteria, and risk.
2. Codex implements, unless another tool is explicitly selected.
3. Implementer runs appropriate validation.
4. A clean checkpoint or authorized commit is created.
5. Claude reviews medium/high-risk or milestone changes, read-only (§I).
6. Reviewer reports actionable, evidence-based findings (§G).
7. Codex independently verifies each finding (§H).
8. Only confirmed findings are fixed.
9. Validation is rerun.
10. PM evaluates the evidence.
11. Status and handoff records are updated.

Claude review is not required for every task — only where §I requires it.

## G. Reviewer finding format

Every actionable finding must include:

- severity: `P0`, `P1`, or `P2`
- file and line or symbol
- evidence
- reproduction steps or concrete reasoning
- expected behavior
- minimal recommended fix

Excluded from findings: style preferences, unsupported speculation,
unrelated pre-existing issues, and broad refactors without direct evidence.

## H. Finding triage

The implementation agent classifies each finding as:

- **confirmed** — reproduced or proven by direct reasoning against the code
- **rejected** — evidence does not hold up
- **unable to verify** — cannot be confirmed with available access

Only **confirmed** findings may be changed.

## I. Focelle risk-based review policy

**Claude review is required** for changes touching:

- AVFoundation capture behavior
- Photos authorization or save lifecycle
- deferred photo processing
- camera capability discovery
- camera concurrency and ownership
- Coach state machine
- planner intent, category, or generation integrity
- selected-subject identity
- Analyze / Apply / Undo contracts
- Coach UX redesign
- multi-subsystem architecture
- milestone integration
- signing, TestFlight, privacy, or release changes

**Claude review is normally unnecessary** for:

- small documentation changes
- copy and localization
- formatter-only changes
- mechanical renames
- deterministic test fixture corrections
- isolated compiler fixes with clear diagnostics
- low-risk single-file fixes with direct regression coverage

## J. Evidence levels

| Level | Meaning |
|---|---|
| `CODE EXISTS` | Source is present and compiles. Nothing more is claimed. |
| `AUTOMATED TESTED` | Covered by a unit/integration test that passes. |
| `CI VERIFIED` | Proven by a green GitHub Actions run on a known commit SHA. |
| `PHYSICAL DEVICE VERIFIED` | Observed working on real hardware, with the observation recorded. |
| `USER-OBSERVED FAILURE` | The user directly observed a defect on physical hardware. |
| `BLOCKED` | Cannot be advanced without external credentials, hardware, or infrastructure. |
| `UNKNOWN` | Not assessed against current HEAD. |

Rules:

- Simulator evidence is **not** physical evidence.
- CI success is **not** product acceptance.
- A user-observed physical failure blocks any optimistic product claim until
  the failure is resolved and re-verified.
- Retain exact artifact and source SHA provenance for every claim.

## K. Quota policy

- Codex is the normal daily driver.
- Claude is reserved for high-leverage specialist and review work.
- No automatic cross-review of every change.
- No multiple Claude sessions re-reading the same large codebase.
- Start a new session when role, milestone, branch, worktree, or independent
  task changes.
- Quota/usage monitor data is advisory, not authoritative over the policy
  above.

## L. Required task contract

Every PM task must state:

- tool, session role, model, reasoning effort, session name
- repository/workspace, worktree, branch, task ID
- file-edit permission, commit permission
- the complete prompt
- acceptance criteria
- stop conditions
- report-back condition

## M. Focelle-specific constraints

See [`docs/project-status.md`](project-status.md) and
[`.ai/SESSION.md`](../.ai/SESSION.md) for current details. Standing
constraints:

- The host is Windows with no local iOS build. iOS builds and tests run on
  GitHub Actions macOS runners only.
- iPhone 17e is the primary physical target; iPhone 12 Pro is the
  compatibility target.
- `D:\Focelle` is prohibited — it is not a repository for this project.
- The existing stash (`stash@{0}`) must not be applied, popped, or dropped.
- Draft PRs remain unmerged unless explicitly authorized by the PM.
- No TestFlight, App Store, or public release without explicit
  authorization.
- Product code and hardware claims require evidence at the matching level
  in §J — code presence or CI success alone is never sufficient.
