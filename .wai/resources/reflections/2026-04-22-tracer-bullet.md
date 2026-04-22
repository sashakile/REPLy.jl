---
date: "2026-04-22"
project: "tracer-bullet"
sessions_analyzed: 5
type: reflection
---

## Project-Specific AI Context
_Last reflected: 2026-04-22 · 5+ sessions analyzed_

### Conventions
- MCP adapter dispatch lives in `src/mcp_adapter.jl`; session lifecycle tools are wired there alongside `mcp_call_tool`
- Security validations applied at middleware boundaries: session names validated on entry, eval repr truncated, TCP message size capped, unsupported `module`/`timeout` fields rejected
- CI runs Vale and typos as parallel jobs (split from a single job) — do not merge them back

### Common Gotchas
- Pre-commit `end-of-file-fixer` hook modifies files in place on failure; always re-stage and re-commit after hook auto-fixes
- `wai reflect` outputs an agent prompt to stdout and requires `--inject-content` to complete — it is a two-step workflow, not a single command
- Pipeline steps (implement, review, fix, commit) must run inside subagents (already in bd memories)
- Source changes from a session are NOT automatically committed; check `git status` at session start to catch carry-over uncommitted work

### Architecture Notes
- Middleware stack: SessionMiddleware → EvalMiddleware → UnknownOpMiddleware (3-middleware tracer-bullet subset); remaining 6 (Describe, Interrupt, LoadFile, Completion, Lookup, Stdin) are deferred per-phase
- Transport: TCP listener, newline-delimited JSON framing, flat envelope; `done` status message always terminates a stream
- Phase roadmap: Phase 4A (complete/lookup/load-file), Phase 4B (interrupt), Phase 6 (eval options), Phase 7A (ResourceLimits config) are the active phases in `bd ready`
