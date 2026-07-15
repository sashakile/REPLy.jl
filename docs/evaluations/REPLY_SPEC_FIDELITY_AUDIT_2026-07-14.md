# REPLy.jl—Spec-Fidelity Audit (2026-07-14, round 3)

**What is REPLy.jl?** A TCP/JSON-over-socket interactive Julia REPL server
(`github.com/sashakile/reply.jl`) used here for both human REPL work and
programmatic, agent-driven code evaluation. This is the third evaluation report
in a series against this same build; see `REPLY_STRESS_REPORT_2026-07-14.md`
(committed alongside this one) for the protocol-level findings and
`REPLY_QA_UX_DX_AIX_REPORT_2026-07-14.md` for the interface/agent-experience
findings this audit is independent of.

**Date:** 2026-07-14
**Version:** 0.1.0 (`main`, commit `c1a8d8d`, tree-sha `c1e90dc3…`)—same build as the
sibling stress and QA/UX/DX/AIX reports from this date.
**Method:** this project's own `AGENTS.md`/`openspec/AGENTS.md` tell any AI assistant
working in the repo to treat `openspec/specs/*/spec.md` as "the authoritative spec."
Round 3 takes that instruction at face value and checks the actual server against
every falsifiable `SHALL`/scenario in `security/spec.md` and `resource-limits/spec.md`—not by reading the implementation and assuming it matches, but by grep-verifying each
requirement has a live code path wired into `serve()`, and then hitting several of
them over the wire to confirm.

**Headline: this is the richest vein found across all three rounds.** Two fully-built,
unit-tested capabilities are never wired into the server anyone actually runs. Four
`ResourceLimits` defaults documented in the spec don't match the shipped defaults—by up to 10×. One hard security requirement (`no response is sent` on oversized
messages) is directly contradicted by the code. And the `max_concurrent_evals`
queueing behavior the spec mandates was never built at all—only the reject path
was, which every existing test (including this project's own `qa/concurrency.py`)
already documents as "reject-excess (not queue)" without ever flagging that this
contradicts the spec it's implementing.

---

## 1. Two fully-built, unit-tested features are dead code in the shipped server

**Severity: Critical.** Both of these are real, working, well-tested Julia code—not stubs—that simply have no caller anywhere in `serve()`, `serve_multi()`, or
`build_handler()`. A user who reads the security spec and configures `ResourceLimits`
or expects audited/self-cleaning session behavior gets neither, silently.

### 1.1 Audit logging (`AuditMiddleware`)—spec says SHALL, server does nothing

`security/spec.md`, "Requirement: Audit Logging":

> The server SHALL maintain an in-memory audit log bounded at 100,000 entries...
> Each `AuditLog` entry SHALL contain: `timestamp`, `client_id`, `session_id`,
> `operation`, `user`, `source_ip`, `success`, `error`.
> **Scenario:** WHEN an eval operation completes THEN an `AuditLog` entry is
> written with all fields populated.

`src/middleware/audit.jl` (49 lines) implements exactly this—`AuditMiddleware`,
wired to a `RequestContext`, populating every field the spec lists. It's exported
(`src/REPLy.jl:25`) and has a dedicated, thorough unit-test file
(`test/unit/audit_middleware_test.jl`, 7 test blocks).

It's **never instantiated** by `default_middleware_stack()` (`src/middleware/core.jl:153-155`),
`serve()`, or `serve_multi()`. Grepped every call site in `src/`: the only places
`AuditMiddleware` appears are its own definition, its export, and its unit test.

**Verified live:** started a vanilla `REPLy.serve()` server, ran evals, and confirmed
`describe` lists 16 ops with no audit-related op—consistent with audit logging
being a purely server-side concern, but there is genuinely zero audit trail being
produced anywhere, because the middleware that would produce it isn't in the stack.

**Impact:** the entire "Audit Logging" requirement section of the security spec—five sub-scenarios, a 100k-entry bound, 100 MB file rotation—describes a feature
that doesn't exist for anyone running `julia --project=. server.jl` today, that is,
every user, including `image-analysis/server.jl` and
`middleware_demo/server.jl`. An operator relying on the spec for a compliance or
incident-response story (a *local* execution server that runs arbitrary code is
exactly the kind of tool where "what ran, from where, when" matters) has no
audit trail at all, despite the spec's own`SHALL`language and a green test suite
that never exercises `default_middleware_stack()` against the audit requirement.

### 1.2 Idle-session sweep (`sweep_idle_sessions!`)—spec says SHALL, no background task exists

`session-management/spec.md`:

> Sessions SHALL be automatically closed after `session_idle_timeout_s` seconds of
> inactivity (default 3600 s)... **A background idle sweep runs every 60 seconds.**
> (REQ-RPL-034)
> **Scenario:** WHEN the idle sweep runs while a session has an active eval task
> THEN the session is skipped until the eval completes (REQ-RPL-034b)

`src/session/manager.jl:294-320` implements `sweep_idle_sessions!(manager;
max_idle_seconds)`—correct semantics, skips running sessions, rejects non-positive
thresholds, and has 5 dedicated unit tests including a concurrency edge case
("doesn't destroy a concurrently-recreated session").

Grepped every call site: the function is called only from its own tests. **There is
no `Timer`, no background `@async` loop, no periodic anything anywhere in
`server.jl` that calls it.** A REPLy server, once started, never closes an idle
session on its own—ever—regardless of how long it sits, contradicting the "every
60 seconds" sweep cadence and the "default 3600s" idle timeout the spec states as a
hard requirement.

**Impact:** this compounds directly with `REPLY_STRESS_REPORT_2026-07-14.md`'s §1
finding and this round's Part A degradation finding—a long-running REPLy server
(exactly the deployment mode the project README recommends: `julia
server.jl &`) accumulates sessions forever. Combined with the `max_sessions` cap
(100 default), a server that's been up for a while and has had 100 sessions
created across its lifetime—closed or not—will hit `session-limit-reached`
on `new-session`/`clone` even though most of those sessions are long-idle and,
per spec, should have been swept away hours earlier.

**Pattern across both:** in both cases the *hard part* (correct concurrency-safe
logic, tested against edge cases) is done. The *easy part*—actually calling the
function from the one entry point (`serve()`) that matters—was never done. This
looks like a wiring gap left behind after implementation, not a design choice
(both docstrings describe production semantics, not "future work").

---

## 2. `ResourceLimits` Defaults: Code and Spec Disagree, by Up to 10×

`resource-limits/spec.md` publishes this as "the single source of truth for field
names, types, and default values." The actual `@kwdef struct ResourceLimits` in
`src/config/resource_limits.jl` disagrees with it on nearly every field it shares a
name with, and doesn't have four of the spec's fields at all.

| Spec field | Spec default | Code field | Code default | Verified live? |
|---|---|---|---|---|
| `max_eval_time_ms` | 60,000 (60s) | `max_eval_time_ms` | **30,000 (30s)** | Yes—timed a `sleep(40)` eval, killed at 30.1s with `"eval timed out after 30000 ms"` |
| `max_message_size` | 10,485,760 (10 MB) | *(not in `ResourceLimits`—separate `serve()` kwarg `max_message_bytes`)* | **1,048,576 (1 MB)** | Yes—an 10.5 MB payload was rejected with `"message exceeds maximum size of 1048576 bytes"` |
| `max_history_entries` | 10,000 | `max_session_history` (renamed) | **1,000** | Not re-verified live this round; code constant is `MAX_SESSION_HISTORY_SIZE` |
| `max_value_repr_bytes` | 1,048,576 (1 MB) | `max_repr_bytes` (renamed) | **`DEFAULT_MAX_REPR_BYTES`, documented as 10 KB** | Consistent with prior reports' observed truncation behavior |
| `max_memory_mb` | 2,048 (2 GB) | *(field doesn't exist)* | *(no enforcement anywhere—zero matches in `src/`)* | N/A—unimplemented |
| `session_idle_timeout_s` | 3,600 (1 hour) | *(field doesn't exist on `ResourceLimits`; only a same-named parameter to the unwired `sweep_idle_sessions!`, §1.2)* | N/A | N/A—unimplemented |
| `min_rate_limit_per_min` | 10 (informative, triggers startup warning) | *(field doesn't exist)* | *(no startup-warning code found)* | N/A—unimplemented |
| `max_id_length` | 256 | hardcoded kwarg on `validate_request`, **not** a `ResourceLimits` field | 256 (matches, coincidentally) | Not configurable despite the spec's "Individual fields overridable" scenario implying every field should be |
| `max_stdin_buffer` | 16 | `MAX_STDIN_BUFFER_SIZE` constant, **not** a `ResourceLimits` field | **256** | Constant, not configurable |
| *(code-only, not in spec at all)* |—| `max_output_bytes` | 1,000,000 | Undocumented in the spec that claims to be the single source of truth |
| *(code-only, not in spec at all)* |—| `max_connections` | 100 | Undocumented in the spec |
| *(code-only, not in spec at all)* |—| `revise_hook_enabled` | `true` | Undocumented in the spec |

Three fields are simply unimplemented (`max_memory_mb`, `session_idle_timeout_s`,
`min_rate_limit_per_min`)—no enforcement code exists anywhere for any of them,
confirmed by exhaustive grep across `src/`. Four more exist under different names
with different (in three cases, 10×+ different) defaults. Three fields the *code*
defines aren't in the spec's table at all. The two documents describe two
different structs.

**Why this matters more than a typical doc-drift bug:** this project's own
`AGENTS.md` explicitly instructs AI assistants to consult these spec files as
authoritative before implementing changes ("Always open `@/openspec/AGENTS.md`
when the request... introduces new capabilities" and treats `openspec/specs/`
as the spec-of-record). Any agent—human or LLM—that reads `resource-limits/spec.md`
to decide "is 60 seconds enough eval time for my workload, or do I need to raise
`max_eval_time_ms`" will make that decision against a number that's wrong by 2×
in the safe direction (the spec claims *more* headroom than the code gives),
which is exactly the kind of drift that produces a confusing "my job times out
faster than I was told to expect" bug report with no obvious cause once the
config was set based on the spec's stated default rather than the code's.

---

## 3. `max_concurrent_evals` Queueing: Spec Mandates a Queue, Only the Reject Path Was Built

`security/spec.md`:

> **Scenario:** Concurrent eval limit enforced with queue
> WHEN `max_concurrent_evals` evals are in flight and a new eval arrives
> THEN it queues FIFO (first-in-first-out) up to 2× limit; beyond the queue it's rejected with
> `{"status":["done","error","concurrency-limit-reached"],"err":"Too many concurrent evals"}`

The actual implementation (`src/middleware/eval.jl:327-332`, confirmed both by
source reading and by the evaluation test suite's `qa/concurrency.py`, which explicitly
labels its own finding `"cap behaviour": "reject-excess (not queue)"`) has **no
queue at all**. Every eval beyond the `max_concurrent_evals` cap is rejected
immediately—there is no FIFO waiting room, no "up to 2× limit" grace band, none
of the mechanism the spec's scenario describes. The error text and status flags
match the spec (`"Too many concurrent evals"`,
`concurrency-limit-reached`)—so a shallow "does the error message match" check
passes—but the actual *behavior* the scenario is testing (queue-then-reject
vs. reject-immediately) was never built, and the existing test suite documents
the simpler behavior as correct without ever cross-checking it against this
scenario.

This also directly explains Round 2's Part A finding (server degrades
permanently after a burst that exceeds the cap): a queue-based design would
naturally backpressure and never need to "reject and discard" 5 half-initialized
eval contexts the way the current reject-path apparently does. The missing
queue and the degradation bug are very plausibly the same root design gap wearing
two different symptoms—worth flagging to whoever picks up the fix for either.

---

## 4. Oversized-message handling directly contradicts its own spec

`security/spec.md`:

> **Scenario:** Oversized message closes connection
> WHEN a message exceeds `max_message_size`
> THEN the connection is closed with an audit-log entry; **no response is sent**

Verified live: sent a 10.5 MB message against the 1 MB actual cap (§2). The server:

```
{"err":"message exceeds maximum size of 1048576 bytes","status":["done","error"],"id":""}
```

**A response is sent**—the opposite of "no response is sent." There is also no
audit-log entry, because (§1.1) no audit logging exists at all in the shipped
server. So this one scenario alone violates two independent clauses of its own
spec: it responds when it shouldn't, and it doesn't audit-log when it should.
The connection *does* subsequently close (that part matches), and the response
itself is reasonably clear and structured—this isn't a case for reverting the
current behavior, which is arguably more useful to a client than silence would
be. It's a case for updating the spec to describe what actually ships, since as
written it asserts the opposite of observed behavior on two counts.

---

## 5. What's confirmed *not* broken (control cases, for calibration)

To keep this audit honest—not every requirement in these two spec files is
wrong:

- **`rate_limit_per_min`** is correctly wired from `ResourceLimits` through to the
  accept loop (`handle.state.limits.rate_limit_per_min`) and the previously-verified
  600-served/100-rejected-on-700-burst pressure result matches the spec's stated
  default (600) exactly.
- **`max_connections`** is correctly wired and enforced (verified in the June 25
  and July 14 stress reports' saturation test), even though—per §2—the field
  itself isn't documented in the spec that claims to enumerate every field.
- **`max_id_length`** enforcement exists and matches the spec's stated default
  (256), even though it isn't wired to `ResourceLimits` and so isn't actually
  configurable the way the spec implies every field should be.
- **The timeout/interrupt race** the spec explicitly calls out ("Eval timeout and
  manual interrupt collision... the first termination cause wins") was stress-tested
  directly this round: 20 trials of firing `interrupt` within 2ms of a 150ms
  eval-timeout boundary on a fresh session, checking for a stale interrupt bleeding
  into the next eval on that session—the exact symptom an upstream bug
  (tracked internally by REPLy's maintainer as `REPLy_jl-b72`: "eval timeout
  Timer can deliver a stale InterruptException to a later eval," fixed by
  running each eval body on a dedicated child task rather than the shared
  connection task) was originally filed against. **0/20
  bleed-throughs.** This looks like a genuine, verified fix—a rare bit of good
  news to report alongside everything above, and worth stating plainly rather than
  only reporting the negative findings.

---

## Priority findings, this round

| # | Finding | Severity |
|---|---|---|
| 1 | `AuditMiddleware` is fully built and tested but never wired into `serve()`—no server run the normal way produces any audit trail | Critical |
| 2 | `sweep_idle_sessions!` is fully built and tested but never called from a background task—idle sessions never expire, compounding the `max_sessions` cap over a long-running server's lifetime | Critical |
| 3 | `max_concurrent_evals` has no queue—the spec's mandated "FIFO up to 2× limit" behavior doesn't exist, only immediate rejection does; plausibly the same root cause as Round 2's server-degradation-after-cap-burst finding | High |
| 4 | Four `ResourceLimits` defaults (`max_eval_time_ms`, `max_message_size`, `max_history_entries`, `max_value_repr_bytes`) disagree with the spec by 2×–10×; three spec fields (`max_memory_mb`, `session_idle_timeout_s`, `min_rate_limit_per_min`) are entirely unimplemented; three code fields aren't in the spec at all | High |
| 5 | Oversized-message handling sends a response and no audit entry, contradicting both halves of its own spec scenario | Medium (behavior is reasonable; the spec is simply wrong about it) |

**Cross-cutting recommendation:** this project has openspec tooling specifically
to keep specs and implementation in sync (`openspec update`, per the managed
block in `AGENTS.md`), and a beads issue tracker already used for granular
implementation tasks (every commit in this window closes a `REPLy_jl-*` issue).
None of the five findings above look hard to fix individually—most are either
"call the function that already exists" (§1) or "update a number in a doc"
(§2, §4). The actual gap is process: nothing currently checks that
`resource-limits/spec.md`'s field table matches `ResourceLimits`'s actual fields,
or that every middleware exported from `REPLy.jl` is reachable from
`default_middleware_stack()`. A cheap, high-leverage addition: a single test
that diffs `fieldnames(ResourceLimits)` against the spec's field table, and
another that asserts every exported `*Middleware` type appears in
`default_middleware_stack()` unless explicitly allow-listed as opt-in (audit
logging plausibly *should* be opt-in given it needs a `client_id`/`source_ip`
per-connection—but that's a design decision to make explicitly, not a gap to
leave silent).
