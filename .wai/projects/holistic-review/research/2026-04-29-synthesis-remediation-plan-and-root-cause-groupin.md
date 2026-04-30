---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

# Synthesis: Remediation Plan and Root-Cause Grouping

**Pass:** REPLy_jl-umg.13 — Final synthesis across all 12 review passes
**Date:** 2026-04-29
**Passes synthesized:** umg.1 (architecture map), umg.2 (docs), umg.3 (contract consistency), umg.4 (Rule of 5 whole-codebase), umg.5 (modularity/composability), umg.6 (session/state invariants), umg.7 (failure handling), umg.8 (adversarial security/bounds), umg.9 (Julia performance), umg.10 (formal verification readiness), umg.11 (test suite), umg.12 (API/MCP/docs UX)
**Open tickets at time of synthesis:** 43 (all open)

---

## Root-Cause Clusters

The 43 open issues group into five underlying root causes. Understanding these clusters prevents treating each bug as isolated and ensures fixes address structural patterns, not just symptoms.

---

### Cluster A — "Enforcement Deferred" (Phantom Configuration)

**Core problem:** Resource limits, security controls, and capability features were implemented as data structures and configuration fields but enforcement was explicitly deferred. Users and operators see a fully populated API surface while the runtime enforces nothing.

**Issues in cluster:**
- `REPLy_jl-9ms` / `REPLy_jl-9ns` — `readline()` pre-allocates unbounded memory before size check fires (OOM DoS)
- `REPLy_jl-xvl` — `max_output_bytes` and `max_session_history` ResourceLimits fields are not enforced at runtime
- `REPLy_jl-gk2` — AuditLog is implemented but `record_audit!` is never called in production paths
- `REPLy_jl-exj` — `max_sessions` enforcement is non-atomic (MATH-1)
- `REPLy_jl-cwb` — `EVAL_IO_CAPTURE_LOCK` serializes all evals globally, defeating `max_concurrent_evals`

**Why this matters:** A server operator reading `ResourceLimits` documentation will configure `max_output_bytes=1_000_000` expecting output to be bounded, but the runtime enforces nothing. The audit module is security theater. These are false comfort configurations.

**Fix pattern:** For each deferred field, wire it into the enforcement path in a single focused ticket. Do not add configuration fields without immediately wiring enforcement.

---

### Cluster B — Security-by-Opt-In (Dangerous Capabilities with No Safe Default)

**Core problem:** Several dangerous middleware capabilities exist without secure-by-default protection, no allowlists, and no warnings when added without hardening. The MCP adapter and TCP endpoint expose unauthenticated eval to the network.

**Issues in cluster:**
- `REPLy_jl-2v5` — `LookupMiddleware._lookup_symbol` executes arbitrary user input via `Core.eval` (RCE)
- `REPLy_jl-7u4` — `load-file` reads arbitrary files with no default allowlist (C-2)
- `REPLy_jl-3a9` — No authentication on TCP eval endpoint
- `REPLy_jl-aof` — `eval` 'module' field allows targeting Main and system modules
- `REPLy_jl-1i8` — Revise hook executes caller-controlled `Main.Revise.revise()`
- `REPLy_jl-6tk` — No TCP connection count limit (connection exhaustion)
- `REPLy_jl-uu1` — `stdin_channel` is unbounded `Channel{String}(Inf)` (heap exhaustion)

**Why this matters:** LookupMiddleware is a remote code execution vector. Load-file reads arbitrary filesystem paths. The TCP endpoint has no authentication whatsoever. These are the issues that must be resolved before any public network exposure.

**Fix pattern:** For RCE vectors, change the implementation to not eval user input. For dangerous opt-in middleware, add secure-by-default wrappers or deny-by-default allowlists. For resource exhaustion, add bounded channels and connection limits.

---

### Cluster C — Shared Mutable State Without Lock Discipline

**Core problem:** Several shared data structures are mutated from multiple concurrent tasks without locks, or with insufficient lock scope. The session lifecycle helpers enforce locking on some transitions but not others, creating TOCTOU windows and partial-state races.

**Issues in cluster:**
- `REPLy_jl-h7o` — `close` vs running eval race — close does not acquire eval_lock (HAZ-1)
- `REPLy_jl-6fh` — Clone registration races with binding copy (IS-7)
- `REPLy_jl-na0` — Alias replacement creates detached session objects (IS-3)
- `REPLy_jl-tox` — `active_eval_tasks` bookkeeping leak on invalid module path (IS-6)
- `REPLy_jl-qr9` — `clients` and `client_tasks` vectors mutated from multiple tasks without a lock
- `REPLy_jl-wep` — InterruptMiddleware and StdinMiddleware bypass ctx.session, re-resolve from manager with TOCTOU window (COMP-1)
- `REPLy_jl-gfo` — MCP adapter bypasses SessionOpsMiddleware for session lifecycle, omitting session limit enforcement

**Why this matters:** A close operation can remove a session from the registry while an active eval is running on it, leaving a detached but running eval on a "destroyed" session object. A clone can publish a partially initialized session. These are data integrity and liveness failures.

**Fix pattern:** For each race, define the lock that owns the invariant and ensure all paths that observe or mutate the protected state hold that lock. Prefer two-phase patterns (prepare privately, publish atomically).

---

### Cluster D — Code Duplication and Structural Coupling

**Core problem:** Several important behaviors are copy-pasted across multiple files without a shared abstraction, meaning any change to the behavior requires manual synchronization. Several module-level globals create implicit coupling between files that is not visible in the dependency graph.

**Issues in cluster:**
- `REPLy_jl-1jy` — `EVAL_IO_CAPTURE_LOCK` shared implicitly between eval.jl and load_file.jl via include order (MOD-2)
- `REPLy_jl-6sr` — No abstract server handle type; shutdown logic duplicated across TCPServerHandle/UnixServerHandle/MultiListenerServer (MOD-1)
- `REPLy_jl-e9g` — Ephemeral session lifecycle and named-session eval serialization duplicated in eval.jl and load_file.jl (COMP-2)
- `REPLy_jl-ktf` — Session limit check copy-pasted three times (COMP-3)
- `REPLy_jl-fyr` — LoadFileMiddleware, CompleteMiddleware, LookupMiddleware absent from default_middleware_stack
- `REPLy_jl-dxp` / `REPLy_jl-cwb` — EVAL_IO_CAPTURE_LOCK serializes all evals globally (same root, correctness + performance impact)

**Why this matters:** The eval lifecycle pattern is duplicated verbatim in eval.jl and load_file.jl. Any lock discipline change must be applied twice. The session limit check is copy-pasted in three places. The shutdown logic exists in two independent code paths that can drift.

**Fix pattern:** Extract shared helpers (`with_session_eval`, `check_session_limit`, abstract server handle). Move `EVAL_IO_CAPTURE_LOCK` to a shared location where the dependency is explicit.

---

### Cluster E — Documentation and API Surface Misalignment

**Core problem:** The documentation teaches unexported internal symbols as primary API, contains stale capability matrices, omits the `"done"` flag from error response examples, and documents wrong return types for key MCP adapter functions.

**Issues in cluster:**
- `REPLy_jl-2j0` — Docs teach unexported symbols as primary API (SessionManager, create_named_session!, EvalMiddleware, SessionMiddleware)
- `REPLy_jl-2r9` — status.md capability matrix incorrectly shows Unix sockets as not implemented
- `REPLy_jl-8tq` — `mcp_ensure_default_session!` docs say it returns name string but it returns UUID
- `REPLy_jl-a28` — `mcp_new_session_result` docs show wrong content format — regex example crashes on real output
- `REPLy_jl-bxo` — api.md is an autodoc stub with no prose — unusable without a rendered docs site
- `REPLy_jl-c3z` — howto-mcp-adapter.md has no end-to-end example
- `REPLy_jl-dx7` — index.md middleware example silently degrades server (replaces full default stack with 2 elements)
- `REPLy_jl-hdr` — tutorial-custom-client.md misidentifies JSON3 as a standard library
- `REPLy_jl-it7` — howto-mcp-adapter.md never shows how to instantiate a JSONTransport
- `REPLy_jl-r50` — howto-sessions.md error response examples omit 'done' flag — clients may loop forever

**Why this matters:** Clients written from the documentation will loop forever waiting for a `"done"` that already arrived. The MCP regex example will crash with a null dereference. New contributors learn to depend on internal symbols with no stability contract.

**Fix pattern:** Fix factual errors first (wrong return types, missing 'done', crashing regex). Then resolve the API surface question (export the symbols or change the docs to use only exported API).

---

## Security Floor

**Minimum fixes before any public network exposure (LAN, container, or CI-exposed port).**

These seven issues collectively represent RCE, OOM DoS, and unauthenticated network access. All must land before external exposure:

| Priority | Issue | Description | Fix type |
|----------|-------|-------------|----------|
| P1-CRITICAL | `REPLy_jl-2v5` | LookupMiddleware executes user input via Core.eval (RCE) | Change implementation — never eval user-supplied symbol strings |
| P1-CRITICAL | `REPLy_jl-9ms` / `REPLy_jl-9ns` | readline() OOM DoS — pre-allocates attacker-controlled buffer | Replace readline() with bounded streaming reader |
| P1-CRITICAL | `REPLy_jl-7u4` | load-file reads arbitrary files — no default allowlist | Add deny-by-default allowlist; warn or refuse when no allowlist provided |
| P1-CRITICAL | `REPLy_jl-3a9` | No authentication on TCP eval endpoint | Structural: document that TCP should only listen on localhost unless auth is added |
| P1-HIGH | `REPLy_jl-aof` | eval 'module' field allows targeting Main and system modules | Blocklist Main and Core modules from eval routing |
| P1-HIGH | `REPLy_jl-6tk` | No connection count limit — connection exhaustion possible | Add `max_connections` limit enforced in accept loop |
| P1-HIGH | `REPLy_jl-uu1` | stdin_channel is unbounded Channel{String}(Inf) | Replace with bounded channel; add backpressure or drop policy |

**Note on authentication (REPLy_jl-3a9):** REPLy is a local developer tool by design. The near-term fix is a README warning and a `localhost_only=true` default or similar guard. A full auth system is a future architectural decision.

---

## Correctness Floor

**Race conditions and logic bugs that affect reliability under concurrent use. Should land in Phase 2.**

| Priority | Issue | Description |
|----------|-------|-------------|
| P1 | `REPLy_jl-h7o` | close vs running eval race (HAZ-1) — close must acquire eval_lock |
| P1 | `REPLy_jl-6fh` | clone registration races with binding copy (IS-7) — two-phase pattern required |
| P1 | `REPLy_jl-na0` | alias replacement creates detached session objects (IS-3) |
| P1 | `REPLy_jl-tox` | active_eval_tasks bookkeeping leak on invalid module path (IS-6) |
| P1 | `REPLy_jl-wep` | InterruptMiddleware/StdinMiddleware TOCTOU — re-resolve from manager bypassing ctx.session |
| P2 | `REPLy_jl-exj` | max_sessions enforcement is non-atomic |
| P2 | `REPLy_jl-qr9` | clients/client_tasks vectors mutated without lock |
| P2 | `REPLy_jl-gfo` | MCP adapter bypasses SessionOpsMiddleware session limit enforcement |
| P2 | `REPLy_jl-xvl` — max_output_bytes / max_session_history not enforced |

---

## Performance Blockers

**P1 performance issues that break core throughput guarantees.**

| Priority | Issue | Description |
|----------|-------|-------------|
| P1 | `REPLy_jl-65d` | Replace mktemp IO capture with pipe-based capture in _run_eval_core |
| P1 | `REPLy_jl-dxp` | EVAL_IO_CAPTURE_LOCK serializes all evals globally — max_concurrent_evals is a lie |
| P2 | `REPLy_jl-a4o` | per-eval @async stdin feeder Task + Pipe allocation on named-session hot path |
| P2 | `REPLy_jl-iuq` | @async timeout task + closure heap allocation per eval |
| P2 | `REPLy_jl-e30` | invokelatest world-age barrier on every named-session eval even when Revise is absent |
| P2 | `REPLy_jl-y31` | receive() materializes JSON3.Object to Dict{String,Any} on every inbound message |

The two P1 performance bugs together mean the server cannot deliver concurrent eval throughput despite being configured for it. `EVAL_IO_CAPTURE_LOCK` is held across the entire `Core.eval()` call, serializing every request regardless of `max_concurrent_evals`. The mktemp IO capture adds filesystem round-trips to every eval.

---

## Remediation Phases

### Phase 1 — Security Floor (~1 week)

**Goal:** No dangerous capabilities exposed; all RCE and OOM DoS vectors closed.

1. Fix `LookupMiddleware._lookup_symbol` — remove `Core.eval` on user input; use `getfield` traversal or documentation lookup instead (`REPLy_jl-2v5`)
2. Replace `readline()` in `receive()` with bounded streaming reader (`REPLy_jl-9ms`, `REPLy_jl-9ns`)
3. Add deny-by-default allowlist to `LoadFileMiddleware` (`REPLy_jl-7u4`)
4. Blocklist Main and Core modules from eval `module` field routing (`REPLy_jl-aof`)
5. Add `max_connections` limit to accept loop (`REPLy_jl-6tk`)
6. Replace `stdin_channel` unbounded channel with bounded alternative (`REPLy_jl-uu1`)
7. Document TCP localhost-only recommendation (partial fix for `REPLy_jl-3a9`)

**Exit criterion:** No open P1 security tickets. The server can be exposed on a LAN without RCE or OOM risk from the protocol layer.

---

### Phase 2 — Correctness (~1 week)

**Goal:** Session lifecycle races resolved; resource limit enforcement wired; bookkeeping exact.

1. Fix `close` vs eval race — acquire `eval_lock` before destroying session (`REPLy_jl-h7o`)
2. Fix `clone` registration race — two-phase: copy privately, publish atomically (`REPLy_jl-6fh`)
3. Fix alias replacement creating detached objects (`REPLy_jl-na0`)
4. Fix `active_eval_tasks` bookkeeping leak on invalid module path (`REPLy_jl-tox`)
5. Fix `InterruptMiddleware`/`StdinMiddleware` to consume `ctx.session` instead of re-resolving (`REPLy_jl-wep`)
6. Fix `max_sessions` enforcement to be atomic (check-and-create under lock) (`REPLy_jl-exj`)
7. Wire `record_audit!` into runtime failure paths — oversized messages, rate limits, denials (`REPLy_jl-gk2`)
8. Enforce `max_output_bytes` and `max_session_history` from `ResourceLimits` config (`REPLy_jl-xvl`)
9. Lock `clients`/`client_tasks` vectors in TCPServerHandle (`REPLy_jl-qr9`)
10. Wire `MCP adapter` session lifecycle through `SessionOpsMiddleware` to enforce limits (`REPLy_jl-gfo`)

**Exit criterion:** No open P1 correctness tickets. Session lifecycle invariants hold under concurrency. Resource limits enforce what the config surface promises.

---

### Phase 3 — Performance + DX (~2 weeks)

**Goal:** Eval throughput scales with `max_concurrent_evals`; documentation accurately reflects the API.

**Performance (week 1):**
1. Replace mktemp IO capture with pipe-based capture (`REPLy_jl-65d`)
2. Eliminate global `EVAL_IO_CAPTURE_LOCK` blocking all concurrent evals — design per-session IO capture (`REPLy_jl-dxp`)
3. Move `EVAL_IO_CAPTURE_LOCK` to shared location with explicit dependency (`REPLy_jl-1jy`)
4. Reduce per-eval task/pipe allocation on named-session hot path (`REPLy_jl-a4o`)
5. Replace `invokelatest` with direct dispatch when Revise is absent (`REPLy_jl-e30`)
6. Reduce timeout task churn (`REPLy_jl-iuq`)

**Documentation + DX (week 2):**
7. Fix factual doc errors: missing `"done"` flag, wrong return type for `mcp_ensure_default_session!`, crashing regex in `mcp_new_session_result` example, JSON3 misidentified as stdlib (`REPLy_jl-r50`, `REPLy_jl-8tq`, `REPLy_jl-a28`, `REPLy_jl-hdr`)
8. Update status.md capability matrix (Unix sockets ARE implemented) (`REPLy_jl-2r9`)
9. Fix index.md middleware example that silently breaks the server (`REPLy_jl-dx7`)
10. Add end-to-end MCP adapter example with JSONTransport instantiation (`REPLy_jl-c3z`, `REPLy_jl-it7`)
11. Resolve API surface question: export the symbols docs use, or rewrite docs to use only exported API (`REPLy_jl-2j0`)
12. Add `LoadFileMiddleware`, `CompleteMiddleware`, `LookupMiddleware` to default stack after security hardening (`REPLy_jl-fyr`)

**Exit criterion:** Eval throughput scales roughly linearly with `max_concurrent_evals`. All documentation code examples are correct and runnable. No critical doc accuracy bugs remain.

---

## Quick Wins

Low-risk, high-value fixes that can be done in any order and don't require design decisions:

| Issue | Fix | Time estimate |
|-------|-----|---------------|
| `REPLy_jl-2r9` | Update status.md Unix socket matrix entry | 15 min |
| `REPLy_jl-hdr` | Fix JSON3 misidentified as stdlib | 5 min |
| `REPLy_jl-r50` | Add missing `"done"` to error response examples in howto-sessions.md | 15 min |
| `REPLy_jl-8tq` | Fix mcp_ensure_default_session! documented return type | 10 min |
| `REPLy_jl-a28` | Fix mcp_new_session_result doc regex | 10 min |
| `REPLy_jl-e30` | Guard invokelatest with `isdefined(Main, :Revise)` before the world-age barrier | 30 min |

These six can be batched into a single "docs accuracy" commit before any Phase 1 work begins.

---

## Deferred (Post-Stabilization)

These Medium/Low findings are valid but should wait until Phase 1 and 2 are complete:

- `REPLy_jl-y31` — JSON3.Object to Dict copy on inbound message (medium perf)
- Abstract server handle type and shutdown deduplication (`REPLy_jl-6sr`) — architectural refactor, safe to defer
- Test suite abstraction: async harness helpers, session-ops table-driven tests, context builders — no functional risk, improves maintainability
- Contract ambiguity resolution: `close` success status flag, `clone` empty-session semantics, `ls-sessions` canonical key, missing `id` policy — these need design decisions before implementation
- `bxo` — api.md autodoc stub — requires either hosting a doc site or writing prose; deferred until Phase 3 DX work is complete
- Formal verification (TLA+ model for session lifecycle) — Phase 3+ after correctness floor is established
- Receive() materialization optimization (`REPLy_jl-y31`) — after correctness and security work

---

## Summary Statistics

| Category | P1 Count | P2 Count | Total |
|----------|----------|----------|-------|
| Security (Cluster B) | 7 | 0 | 7 |
| Correctness/Race (Cluster C) | 5 | 5 | 10 |
| Performance (Cluster D-perf) | 2 | 4 | 6 |
| Phantom Config (Cluster A) | 2 | 3 | 5 |
| Duplication/Coupling (Cluster D) | 0 | 6 | 6 |
| Documentation (Cluster E) | 1 | 9 | 10 |
| **Total** | **17** | **27** | **44** |

(44 includes the parent epic ticket)

---

## Key Risks If Remediation Is Not Sequenced Correctly

1. **Fixing performance before security:** Adding `LoadFileMiddleware` etc. to the default stack before security hardening would expose the RCE vector broadly.
2. **Fixing duplication before correctness:** Extracting `with_session_eval` helper before the eval lifecycle races are fixed embeds the race into a shared abstraction.
3. **Fixing docs before the API surface decision:** If docs are rewritten to use `using REPLy:` exported symbols, but the export decision changes later, the docs need another pass.

**Recommended order:** Phase 1 (security) → Phase 2 (correctness) → Quick wins (can go any time) → Phase 3 (performance + DX) → Deferred.
