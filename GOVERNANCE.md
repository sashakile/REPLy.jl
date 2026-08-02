# REPLy.jl Governance

## REPLy.jl Charter — for Stakeholders

**Purpose:** Provide a structured, session-isolated network REPL protocol for Julia — the equivalent of Clojure's nREPL — so editors, IDEs, MCP servers, and CLI tools can evaluate Julia code interactively.

**Core principles:**
- **Session isolation** — every evaluation context is an isolated Julia module; concurrent sessions cannot observe each other's bindings.
- **Safety first** — localhost-only by default, resource limits enforced, audit logging available, Unix socket permission fences.
- **Protocol over implementation** — the wire format (newline-delimited JSON) is the contract; the reference implementation is one consumer of that contract.
- **Composability** — middleware pipeline for extensibility; no operation is hard-coded into the transport.

**In scope:** TCP and Unix socket transports, session lifecycle (create/list/close/clone), code evaluation with streaming stdout/stderr, tab-completion, documentation lookup, file loading, MCP adapter, Revise integration, resource limit enforcement, audit logging.

**Out of scope:** Remote authentication (TLS, auth middleware), heavy sessions (Malt.jl), multi-process execution sandboxing, post-v1.0 protocol extensions.

**Prohibitions:**
- MUST NOT bind on non-loopback addresses without a startup warning.
- MUST NOT expose sessions to untrusted network callers.
- MUST NOT execute code without resource limit enforcement.
- MUST NOT persist audit logs without rotation.
- MUST NOT silently swallow resource-limit violations.

**Success criteria:**
- v1.0: All P0 requirements from the spec pass conformance tests.
- v1.0: At least one external tool building on REPLy.
- Six-month: ≥20 GitHub stars, ≥1 external contributor.

**Governance:** Spec changes via OpenSpec proposals; code changes via bead-tracked issues with PR reviews; behavioral regression tests on every PR CI run.

---

## Behavioral Specification Document (BSD)

### 1. Purpose and Objective

REPLy.jl exists so that Julia tool builders can ship structured REPL interaction into their editors, IDEs, and MCP servers — cutting integration time from days to minutes.

> Verbatim objective: "Enable Julia tool builders to ship structured REPL interaction into their editors, IDEs, and MCP servers, cutting integration time from days to minutes, as measured by time-to-first-successful-eval for a new client."

This objective appears verbatim in:
- This BSD (§1)
- The MCP adapter tool description (Goal Sandwich)
- The quarterly Value Realization Review agenda

### 2. Authorized Behaviors

The reference server implementation (the REPLy server, `replyc` CLI, and MCP adapter) is authorized to:

1. Accept TCP connections on configured ports (default 127.0.0.1:5555).
2. Accept Unix socket connections at configured paths.
3. Parse newline-delimited JSON messages from connected clients.
4. Route messages through the middleware pipeline to the appropriate operation handler.
5. Evaluate submitted Julia code within properly isolated sessions.
6. Stream stdout/stderr output back to clients before eval completion.
7. Return structured errors for runtime and protocol violations.
8. Manage session lifecycle (create, clone, list, close).
9. Enforce configured resource limits (eval timeout, message size, output size, concurrent evals, session count).
10. Log audit entries for all operations when audit is enabled.
11. Integrate with Revise.jl for hot-reloading code changes.
12. Expose operations via the MCP adapter as MCP tools.
13. Shut down cleanly on SIGTERM or `shutdown` RPC.

### 3. Prohibited Behaviors

The server MUST NOT:

1. **Evaluate code without session isolation** — every eval must go through a session; ephemral evals use a temporary session.
2. **Bind on non-loopback addresses silently** — non-loopback bindings MUST emit a `@warn`-level log message.
3. **Accept unauthenticated remote connections** — no remote auth in v1.0; TCP MUST default to loopback.
4. **Execute code beyond configured resource limits** — timeout, message size, output size, and concurrency limits MUST be enforced.
5. **Leak state across sessions** — concurrent sessions MUST NOT observe each other's bindings.
6. **Silently drop audit entries** — audit log eviction MUST be documented and bounded.
7. **Expose full stacktraces to untrusted clients** — error responses MUST be structured and non-revealing of internal state.
8. **Orphan active evaluations on disconnect** — client disconnect MUST trigger cleanup of in-flight evals in that session.
9. **Retain session state after server restart** — in-memory only; documented limitation.
10. **Allow dangerous eval patterns in MCP adapter without guard** — the MCP adapter MUST refuse or warn on pattern-matched dangerous code (filesystem writes, shell execution, network access).

### 4. Escalation Triggers

The MCP adapter and `replyc` client MUST stop-and-signal (rather than silently proceed) in these situations:

| Trigger | Definition | Behavior |
|---------|------------|----------|
| **Resource limit reached** | `max_eval_time_ms`, `max_message_size`, `max_concurrent_evals` or session limit hit | Return structured error with descriptive status flag |
| **Dangerous eval pattern** | Code matching `run(`, `write(`, `download`, `rm(` at the top level | Return error: "Code matches a prohibited pattern; override with `--allow-unsafe`" |
| **Scope violation** | Connection from non-loopback source without explicit override | Emit warning, accept connection (v1.0 behavior) |
| **Irreversible action** | Shutdown, session destroy on session with in-flight evals | Block until evals complete or timeout, then proceed |
| **Unexpected state** | Message with unknown `op`, malformed JSON, or unrecognized `session` ID | Return structured error; do not crash |
| **High stakes** | Code evaluating in the MCP adapter's default session (shared state risk) | Log evaluation; document in BSD |
| **Confidence below threshold** | Internal error during dispatch, middleware stack validation failure | Refuse to start: throw `ArgumentError` with validation details |

### 5. Behavioral Principles

| Principle | Meaning |
|-----------|---------|
| **Protocol over implementation** | The wire format is the contract. Any compliant client can talk to any compliant server. |
| **Isolation by default** | Sessions are silos unless explicitly shared. No binding leakage. |
| **Fail closed** | When in doubt about safety, refuse the operation. |
| **Graceful degradation** | Optional dependencies (Revise, Malt) fail absent without crashing. |
| **Auditability** | All operations leave a trace when audit is enabled. |
| **Minimal footprint** | Do only what the request asks; no side-band work, no unexpected resource consumption. |

### 6. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Protocol conformance | All P0 reqs from spec pass | CI conformance tests |
| Eval latency (reference hardware) | <50ms p50, <200ms p99 for trivial eval | Benchmark regression gate |
| Session creation latency | <5ms p50 | Benchmark |
| MCP adapter tool correctness | All scenario tests pass | CI |
| External adopters | ≥1 tool built on REPLy by v1.0 | Downstream dependents tracking |
| CI stability | <5% flaky test rate | CI history |

### 7. Known Limitations and Edge Cases

- **No persistence:** Session state is lost on server restart. Named sessions survive only as long as the server process.
- **No remote auth:** TLS/authentication middleware is deferred post-v1.0. TCP connections must be localhost-trusted.
- **No heavy sessions:** Malt.jl integration for sub-process execution is post-v1.0.
- **Ephemeral module reuse:** Ephemeral sessions may reuse modules within the same connection; documented limitation.
- **Double-done path:** The `_eval_inner` path has had one parsing edge case (double-`done`); fixed in v1.3.1.
- **MCP adapter eval scope:** The default MCP session (`mcp-default`) holds shared state across MCP tool calls — users should create named sessions for isolation.

### 8. Scope Gates

| Gate | Trigger | Action |
|------|---------|--------|
| New operation | Openspec proposal | Requires BADR with behavioral impact assessment |
| New transport | Openspec proposal | Requires security review of transport properties |
| Non-loopback TCP | Code change | Requires explicit override and startup warning |
| Dependency addition | PR | Requires justification and test coverage |
| Behavioral regression | Test failure in CI | Block merge until resolved or acknowledged |

### 9. Review Cadence

| Ceremony | Frequency | Covers |
|----------|-----------|--------|
| Behavioral regression testing | Per sprint boundary | Eval pass rate, goal achievement, scope violations |
| Code review | Every PR | Functional correctness, style, test coverage |
| Value Realization Review | Quarterly | VP evidence review, gap analysis, continue/pivot/kill |
| Red-team review | Pre-v1.0, then annually | Goal drift, specification gaming, scope violation attempts |
| Security audit | Pre-v1.0, then annually | Code review, dependency audit, threat model |

---

*This document is version-controlled with the same rigor as code. All changes require a BADR (Behavioral ADR).*
