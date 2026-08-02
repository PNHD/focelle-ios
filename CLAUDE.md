# Focelle iOS — Claude Code Instructions

Canonical multi-agent workflow: [`docs/AI_WORKFLOW.md`](docs/AI_WORKFLOW.md).
Read it, along with [`docs/project-status.md`](docs/project-status.md),
[`docs/focelle-spec.md`](docs/focelle-spec.md), and any architecture or
handoff notes referenced there, before starting any task.

- Claude Code is the specialist and independent reviewer: architecture,
  deep debugging with an unclear root cause, complex refactors,
  multi-subsystem state, privacy/capture lifecycle, product-intent
  alignment, and milestone/release review. See `docs/AI_WORKFLOW.md` §I
  for exactly which changes require Claude review.
- **Review sessions are read-only.** Do not edit files during a review
  unless the PM's task explicitly grants write permission for that
  session (as stated in the task prompt).
- Review against an immutable `BASE..HEAD` (or equivalent) boundary — do
  not review a moving target.
- Report findings as actionable `P0`/`P1`/`P2` items only: file/line or
  symbol, evidence, reproduction or concrete reasoning, expected behavior,
  and a minimal recommended fix (`docs/AI_WORKFLOW.md` §G).
- Do not report style-only preferences, unsupported speculation, unrelated
  pre-existing issues, or broad refactors without direct evidence.
- Ground every judgment in product intent and the actual evidence level
  (`docs/AI_WORKFLOW.md` §J) — simulator success and CI success are not
  physical or product evidence, and a user-observed physical failure
  overrides an optimistic code-level read.
