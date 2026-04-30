---
date: 2026-04-28T23:23:21-03:00
git_commit: 7ce3c32
branch: main
directory: /var/home/sasha/para/areas/dev/gh/sk/REPLy.jl
issue: REPLy_jl-umg.3
status: handoff
---

# Handoff: holistic-review docs and contract audit

## Context

This session completed two review-only tickets in the `holistic-review` project:
- `REPLy_jl-umg.2` — documentation inventory and link audit
- `REPLy_jl-umg.3` — protocol/runtime/docs/tests consistency review

No source code was changed. The work produced two `wai` research artifacts and updated beads state. The most important outcome is that the codebase's implemented behavior is ahead of its written contract in several places: `docs/src/status.md` is materially stale, `docs/src/reference-protocol.md` is incomplete relative to implemented ops, and OpenSpec diverges from runtime/tests for several session and protocol details.

## Current Status

### Completed
- [x] Completed docs inventory + link verification for `REPLy_jl-umg.2`; recorded findings in `.wai/projects/holistic-review/research/2026-04-29-title-documentation-research-reply-jl-reply-j.md`
- [x] Completed contract consistency review for `REPLy_jl-umg.3`; recorded findings in `.wai/projects/holistic-review/research/2026-04-29-title-contract-consistency-review-reply-jl-re.md`
- [x] Closed `REPLy_jl-umg.2` and `REPLy_jl-umg.3` in beads

### In Progress
- [ ] No implementation work in progress
- [ ] Review backlog remains for the `holistic-review` epic; next best ticket is `REPLy_jl-umg.6`

### Planned
- [ ] Continue with `REPLy_jl-umg.6` — reevaluate session/state invariants and shared mutability
- [ ] File follow-up beads tickets for the mismatches found if the user wants actionable decomposition before more review passes

## Critical Files

1. `.wai/projects/holistic-review/research/2026-04-29-title-documentation-research-reply-jl-reply-j.md` - Full report for `REPLy_jl-umg.2`; includes docs inventory, link audit, and docs/code surface gaps
2. `.wai/projects/holistic-review/research/2026-04-29-title-contract-consistency-review-reply-jl-re.md` - Full report for `REPLy_jl-umg.3`; includes consistency matrix and prioritized mismatch list
3. `docs/src/status.md` - Highest-severity docs trust problem; materially stale against current implementation
4. `docs/src/reference-protocol.md` - Claims to be complete but omits implemented operations like `describe`, `load-file`, `interrupt`, `complete`, `lookup`, and `stdin`
5. `src/middleware/session_ops.jl` - Central file for `new-session`, `ls-sessions`, `close`, and `clone`; key source of spec/runtime divergence
6. `src/session/manager.jl` - Important for clone/close concurrency semantics; current implementation does not acquire `eval_lock` for clone/close the way OpenSpec says
7. `src/session/module_session.jl` - Defines the actual runtime session lifecycle model (`SessionIdle`, `SessionRunning`, `SessionClosed`)
8. `src/protocol/message.jl` - Ground truth for request validation and missing-`id` / missing-`op` behavior

## Recent Changes

- `.wai/projects/holistic-review/research/2026-04-29-title-documentation-research-reply-jl-reply-j.md` - Added documentation architecture/link audit report for `REPLy_jl-umg.2`
- `.wai/projects/holistic-review/research/2026-04-29-title-contract-consistency-review-reply-jl-re.md` - Added protocol/runtime/docs/tests consistency report for `REPLy_jl-umg.3`
- `.beads/issues.jsonl` - Updated by claiming and closing `REPLy_jl-umg.2` and `REPLy_jl-umg.3`
- `.wai/projects/holistic-review/handoffs/2026-04-28-session-end.md` - Marked modified in working tree before this handoff; review if you plan to keep or replace it

## Key Learnings

1. `docs/src/status.md` is not just slightly stale; it significantly understates the implemented feature set
   - Evidence: `.wai/projects/holistic-review/research/2026-04-29-title-documentation-research-reply-jl-reply-j.md`
2. `docs/src/reference-protocol.md` is internally coherent for the parts it documents, but it is incomplete relative to the implemented middleware surface
   - Evidence: same docs research artifact + `src/middleware/*.jl`
3. Several high-value disagreements are no longer code-vs-test disagreements; they are OpenSpec-vs-runtime/tests/docs disagreements
   - Evidence: `.wai/projects/holistic-review/research/2026-04-29-title-contract-consistency-review-reply-jl-re.md`
4. Two likely real runtime/spec gaps remain around session concurrency semantics
   - Evidence: `src/session/manager.jl` clone/close paths do not acquire `eval_lock`, while OpenSpec requires synchronization semantics for clone/close races
5. The next review pass should focus on session invariants, because the strongest unresolved findings now cluster around clone/close/state-machine behavior
   - Evidence: `REPLy_jl-umg.3` report, especially findings `CC-7` and `CC-8`

## Open Questions

- [ ] Is `new-session` now the canonical empty-session creation op, with `clone` reserved for copy-from-parent only?
- [ ] Should successful `close` return bare `done` or `status:["done","session-closed"]`?
- [ ] Should missing `id` be dropped silently or answered with an error using empty echoed id?
- [ ] Is the intended session lifecycle the current 3-state runtime model or the older 4-state OpenSpec model?
- [ ] Is `ls-sessions` canonical UUID key name `session` or `id`?

## Next Steps

1. Start `REPLy_jl-umg.6` and use the `REPLy_jl-umg.3` artifact as the baseline for session/state review
2. If the user wants tighter work decomposition, create follow-up beads issues for:
   - docs refresh (`docs/src/status.md`, `docs/src/reference-protocol.md`)
   - close success flag normalization
   - clone-without-source contract normalization
   - missing-id contract normalization
   - clone/close synchronization race tests
3. Before any implementation, decide whether the OpenSpec contract or the runtime/tests/docs contract is authoritative for the contested areas

## Artifacts

New files:
- `.wai/projects/holistic-review/research/2026-04-29-title-documentation-research-reply-jl-reply-j.md`
- `.wai/projects/holistic-review/research/2026-04-29-title-contract-consistency-review-reply-jl-re.md`
- `.wai/projects/holistic-review/handoffs/2026-04-28_23-23-21_holistic-review-docs-and-contract-audit.md`

Modified files:
- `.beads/issues.jsonl`
- `.wai/projects/holistic-review/handoffs/2026-04-28-session-end.md`

## Related Links

- `bd show REPLy_jl-umg.2`
- `bd show REPLy_jl-umg.3`
- `bd ready`
- `.wai/projects/holistic-review/research/2026-04-29-title-documentation-research-reply-jl-reply-j.md`
- `.wai/projects/holistic-review/research/2026-04-29-title-contract-consistency-review-reply-jl-re.md`

## Additional Context

The repository is now in a good state for another review pass, not an implementation pass. The strongest unresolved issues are contract-authority questions rather than missing observations. If resuming cold, read the two research artifacts first, then choose between (a) more analysis via `REPLy_jl-umg.6` or (b) turning the ambiguities into concrete follow-up issues.
