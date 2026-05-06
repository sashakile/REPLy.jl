---
date: 2026-04-28T23:39:58-03:00
git_commit: 7ce3c32
branch: main
directory: /var/home/sasha/para/areas/dev/gh/sk/REPLy.jl
issue: REPLy_jl-umg.7
status: handoff
---

# Handoff: holistic-review state and failure review

## Context

This session resumed from the previous `holistic-review` handoff, completed two additional review-only passes, and recorded both as `wai` research artifacts. No runtime or docs files under `src/`, `docs/`, or `test/` were edited. The main work was analytical: `REPLy_jl-umg.6` reviewed session/state invariants and shared mutability, and `REPLy_jl-umg.7` reviewed failure handling and recovery semantics.

The strongest current theme across the review stream is that the codebase often has a coherent local implementation, but cross-cutting contracts are fragmented. For sessions, the key risks are close/clone races, detached session objects, and partial construction/publication semantics. For failure handling, the key risks are inconsistent wire error shapes, weak observability, and an audit subsystem that exists but is not integrated into the reviewed runtime paths.

## Current Status

### Completed
- [x] Completed `REPLy_jl-umg.6` and recorded the report in `.wai/projects/holistic-review/research/2026-04-29-title-session-state-invariants-and-shared-mutab.md`
- [x] Completed `REPLy_jl-umg.7` and recorded the report in `.wai/projects/holistic-review/research/2026-04-29-title-failure-handling-and-recovery-semantics-r.md`
- [x] Closed `REPLy_jl-umg.6` and `REPLy_jl-umg.7` in beads
- [x] Verified the previous `REPLy_jl-umg.2` and `REPLy_jl-umg.3` research artifacts still match the current committed codebase

### In Progress
- [ ] No implementation work is in progress
- [ ] No new code changes were made; working tree contains research artifacts, handoffs, and beads metadata updates only

### Planned
- [ ] Continue the `holistic-review` epic with one of the ready tickets: `REPLy_jl-umg.11`, `REPLy_jl-umg.10`, `REPLy_jl-umg.8`, or `REPLy_jl-umg.4`
- [ ] Optionally create follow-up beads tickets distilled from the `.6` and `.7` findings before starting another broad pass

## Critical Files

1. `.wai/projects/holistic-review/research/2026-04-29-title-session-state-invariants-and-shared-mutab.md` - Full `REPLy_jl-umg.6` report covering invariant catalog, invalid states, concurrency hazards, and missing edge-case tests
2. `.wai/projects/holistic-review/research/2026-04-29-title-failure-handling-and-recovery-semantics-r.md` - Full `REPLy_jl-umg.7` report covering failure taxonomy, recovery semantics, error-shape inconsistencies, and observability gaps
3. `.wai/projects/holistic-review/research/2026-04-29-title-contract-consistency-review-reply-jl-re.md` - Best baseline for contract disagreements between OpenSpec, runtime, tests, and docs
4. `src/session/manager.jl` - Central to the `.6` findings: close/clone semantics, alias replacement, registry integrity, and publication order
5. `src/session/module_session.jl` - Defines the runtime session state machine and the mutable fields whose coherence depends on helper usage and lock discipline
6. `src/middleware/eval.jl` - Central to both `.6` and `.7`: eval lifecycle, timeout behavior, cleanup symmetry, and error-shape fragmentation
7. `src/transport/tcp.jl` - Main transport-boundary failure handling path: oversized messages, rate limiting, handler exception recovery, and disconnect resilience
8. `src/security/audit.jl` - Important because it is implemented and tested, but currently appears unused by the reviewed runtime failure paths

## Recent Changes

- `.wai/projects/holistic-review/research/2026-04-29-title-session-state-invariants-and-shared-mutab.md` - Added the `REPLy_jl-umg.6` session/state invariants and shared mutability review
- `.wai/projects/holistic-review/research/2026-04-29-title-failure-handling-and-recovery-semantics-r.md` - Added the `REPLy_jl-umg.7` failure handling and recovery semantics review
- `.beads/issues.jsonl` - Updated by claiming and closing `REPLy_jl-umg.6` and `REPLy_jl-umg.7`
- `.wai/projects/holistic-review/handoffs/2026-04-28_23-39-58_holistic-review-state-and-failure-review.md` - New handoff for continuity from this point

## Key Learnings

1. Session correctness problems are now mostly about lifecycle semantics and synchronization, not basic feature absence
   - Evidence: `.wai/projects/holistic-review/research/2026-04-29-title-session-state-invariants-and-shared-mutab.md`
2. `close` and `clone` remain the highest-risk session operations because they are not synchronized with `eval_lock` the way the stronger contract would imply
   - Evidence: `src/session/manager.jl`, `src/middleware/session_ops.jl`, and the `.6` report
3. The runtime can represent detached or partially published session objects in more places than the public surface suggests
   - Evidence: `create_named_session!` replacement behavior and `clone_named_session!` publication-before-copy in `src/session/manager.jl`
4. REPLy has multiple distinct failure classes, but they are not encoded consistently enough to count as one coherent failure contract yet
   - Evidence: `.wai/projects/holistic-review/research/2026-04-29-title-failure-handling-and-recovery-semantics-r.md`
5. `AuditLog` is real and tested, but it appears disconnected from the reviewed runtime failure paths
   - Evidence: `src/security/audit.jl`, `test/unit/audit_log_test.jl`, and repo-wide search results summarized in the `.7` report
6. The `eval_responses` invalid-module path still looks like the most concrete cleanup asymmetry across both the state and failure analyses
   - Evidence: `src/middleware/eval.jl` and both `.6` / `.7` research artifacts

## Open Questions

- [ ] Should follow-up work be decomposed into narrow bug/contract tickets now, or should the holistic review continue for another pass first?
- [ ] Is `AuditLog` intentionally not wired into runtime failure paths yet, or is that an omission to track explicitly?
- [ ] Should timeout, module-resolution failure, file-I/O failure, and internal handler exceptions all be normalized under a broader machine-readable error taxonomy?
- [ ] Is silent same-name session replacement intended behavior, or an internal helper convenience that should eventually be removed or constrained?
- [ ] Which ready ticket should be next: `.11` (test suite review), `.10` (formal-verification readiness), `.8` (security/boundary review), or `.4` (Rule-of-5 broad review)?

## Next Steps

1. Decide whether to create follow-up beads tickets from the `.6` and `.7` findings before more review passes
2. If continuing the holistic review directly, the most leverage likely comes from:
   - `REPLy_jl-umg.11` if you want to turn current findings into test-gap analysis
   - `REPLy_jl-umg.10` if you want to reason formally about the session and failure invariants already surfaced
   - `REPLy_jl-umg.8` if you want to pressure-test the boundary and failure surfaces adversarially
3. Before implementation work, use the `.3`, `.6`, and `.7` artifacts together as the contract/risk baseline

## Artifacts

New files:
- `.wai/projects/holistic-review/research/2026-04-29-title-session-state-invariants-and-shared-mutab.md`
- `.wai/projects/holistic-review/research/2026-04-29-title-failure-handling-and-recovery-semantics-r.md`
- `.wai/projects/holistic-review/handoffs/2026-04-28_23-39-58_holistic-review-state-and-failure-review.md`

Modified files:
- `.beads/issues.jsonl`
- `.wai/projects/holistic-review/handoffs/2026-04-28-session-end.md`

## Related Links

- `bd show REPLy_jl-umg.6`
- `bd show REPLy_jl-umg.7`
- `bd ready`
- `.wai/projects/holistic-review/research/2026-04-29-title-contract-consistency-review-reply-jl-re.md`
- `.wai/projects/holistic-review/research/2026-04-29-title-session-state-invariants-and-shared-mutab.md`
- `.wai/projects/holistic-review/research/2026-04-29-title-failure-handling-and-recovery-semantics-r.md`

## Additional Context

The repository is still in a review-heavy state, not an implementation state. The immediate value is in either (a) creating targeted follow-up tickets from the now-accumulated risk inventory, or (b) continuing high-level review with one of the remaining passes while the current findings are still fresh. If resuming cold, read the `.6` and `.7` research artifacts first, then decide whether to branch into deeper analysis (`.10`, `.11`, `.8`) or backlog shaping.
