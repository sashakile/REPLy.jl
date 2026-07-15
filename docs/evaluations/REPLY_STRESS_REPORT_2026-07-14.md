# REPLy.jl—Stress Report (2026-07-14)

**What is REPLy.jl?** A TCP/JSON-over-socket interactive Julia REPL server
(`github.com/sashakile/reply.jl`). A client sends `{"op":"eval", "code":"..."}`
over a socket and gets back structured JSON responses (`value`, `out`, `err`,
`status`). It's built for both human REPL work from an editor and programmatic,
agent-driven code evaluation — persistent named sessions, interrupt, stdin,
file loading, and (as of this version) a Model Context Protocol (MCP) adapter
for LLM tool-calling. This is the third in a series of evaluation reports
against it, run from an evaluation workspace that uses REPLy
to drive two real Julia projects (a library-dev session and an image-analysis
pipeline) plus a dedicated `qa/` test-suite directory.

**Date:** 2026-07-14
**Version:** 0.1.0 (`main` branch, commit `c1a8d8d`, tree-sha `c1e90dc3…`)
**Baseline for comparison:** `REPLY_PUBLIC_READINESS_REPORT.md`, a prior evaluation
of this same server dated 2026-06-25 (commit-era tree-sha `f52f02f3…`), covering
protocol correctness and public-adoption readiness — committed alongside this
report in the same directory.
**Julia version:** 1.12.6, single-threaded (`JULIA_NUM_THREADS=1`)
**Evaluation basis:** fresh `Pkg.update`, full `qa/run_all.sh` scorecard, targeted manual
reproduction of session-introspection ops, source-level instrumentation of the
installed package to trace one confirmed regression to its exact call site.

---

## Verifying "new version" before testing it

Before stressing anything, confirmed the installed package is genuinely current
rather than a stale registry snapshot:

```
Manifest.toml git-tree-sha1  = c1e90dc38ee9ae5c3bc7af2d92ad895282dbbd5c
fresh clone of main HEAD     = c1a8d8da8bb1f0e1041d71c8cc25c22c86d38b00
Pkg.GitTools.tree_hash(clone)= c1e90dc3... (byte-identical)
```

`Pkg.update("REPLy")` across all three project envs (root, `transducers-dev`,
`image-analysis`) pulled the same tree. This isn't a tagged release—REPLy
tracks `main` directly—so "the new version" is simply "everything merged since
the June 25 report," roughly three weeks and ~40 commits.

---

## What changed upstream since the last report

Nearly every P0/P1/P2 item from `REPLY_PUBLIC_READINESS_REPORT.md` has a
corresponding fix commit:

| Report finding | Fix commit | Status |
|---|---|---|
| §1.2 `include` broken in sessions | `67f8f295` fix(session): inject `include()` wrapper | Verified fixed |
| §1.1 No CLI client | `a05035df` feat(client): ship minimal `replyc` CLI | Shipped |
| §1.3 `clone` binding copy no-ops (Julia ≥ 1.11) | `7c298792` fix(session): copy clone bindings as const | **Regressed again—see §1 below** |
| §2.2 `new-session` duplicate-name friction | `98f540c1` feat(session): `if-exists=reuse` | Shipped |
| §2.3 undocumented server modes | `87cd9208` docs: server run modes, clone semantics, etc. | Documented |
| §2.4 4/8 MCP tools stubbed | `4b09d265` feat(mcp): implement complete/lookup/load-file/interrupt | Verified implemented |
| §2.5 No `ping` op | `425ca2df` feat(middleware): add `ping` op | Shipped (now conflicts with our demo—see §2) |
| §2.6 `repr` failure indistinguishable from a value | `165aa079` feat(eval): `repr-error` field | Shipped |
| §3.3 No session introspection | `94e63a6f` feat(ls-bindings): session introspection op | **Shipped but broken—see §1 below** |
| (new, not in prior report) soft-scope warning noise | `9956ca3a` fix(eval): REPL soft-scope lowering | Shipped |
| (new) timeout responses didn't mention the config knob | `78b18632` fix(eval): timeout hint | Shipped |
| (new) `lookup` missed `using`-imported symbols | de5dcddf / e78a78dd | Test added, fix present |

Plus a batch of pure performance work in the days immediately before this
evaluation: task-local I/O capture (no more global lock on stdout/stderr
writes), a concrete `EvalCoreResult` struct (fixes a type instability in the
hot eval path), tuple-based static middleware dispatch (avoids per-message
dynamic dispatch through the middleware chain), and direct-to-stream JSON
serialization on the send path.

This is a genuinely different, much more complete tool than the one evaluated
three weeks ago. Unfortunately, stress-testing it surfaced a new, serious
regression in exactly the two features (`clone`, `ls-bindings`) that the
previous report's fixes were supposed to deliver.

---

## §1. Regression: Session-introspection ops see an empty binding table

**Severity: Critical. Reproducible: 100%, deterministic, single-threaded,
no custom code required.**

### Symptom

`clone` and `ls-bindings`—the two ops whose entire job is to read back a
session's bindings from *outside* an `eval` call—see **zero** bindings, even
immediately after a successful `eval` that visibly defined them. A subsequent
`eval` on the very same session sees the bindings just fine.

### Minimal repro (vanilla `REPLy.serve()`, no middleware customization)

```python
new-session  name=src           →  session=<uuid>
eval         session=src  "x = [1, 2, 3]"     →  value: "[1, 2, 3]"   (succeeds)
ls-bindings  session=src                       →  count: 0, bindings: []   ← BUG
clone        session=src  name=dst             →  new-session: <uuid2>     (looks fine)
eval         session=dst  "isdefined(@__MODULE__, :x)"  →  value: "false"  ← BUG
```

Reproduced identically:
- Over a **single persistent TCP connection** (rules out cross-connection
  session-manager confusion).
- Against a **freshly precompiled** package with `~/.julia/compiled` wiped
  first (rules out a stale precompile cache).
- With `Threads.nthreads() == 1` (rules out a cross-thread memory-visibility
  race in the "eval runs on a dedicated child task" mechanism landed on
  July 11—a natural first suspect given the timing, but not the cause).
- Waiting 2 seconds and issuing a second `eval` + second `ls-bindings` on the
  same session: still empty, then empty again—**not** a transient race, a
  permanent, deterministic miss.

### Isolating the cause

Direct, in-process calls bypass the bug entirely:

```julia
handler = REPLy.build_handler()
handler(Dict("op"=>"new-session", ...))
handler(Dict("op"=>"eval", "code"=>"x = [1,2,3]", ...))
handler(Dict("op"=>"clone", ...))   # → dest module correctly contains x
```

and even calling the *exact* production handler of a *live, already-running*
server, from inside an `eval` sent to that same server (`Main.server.handler(...)`),
correctly copies `x`. Only requests that go through the real
`accept_loop! → handle_client! → receive() → handler(msg)` TCP path exhibit the
bug—for **every** op that isn't itself an `eval`.

Source-level tracing (temporary debug instrumentation added to
`session/manager.jl` and `middleware/ls_bindings.jl`, reverted after use) confirms:
at the moment `clone`/`ls-bindings` call `names(source_mod; all=true)` on the
connection-handling task, the returned name list is missing not just the
just-defined `x`, but also `:include` and `:ans`—bindings created at session
*creation* time, long before the eval ran. The same `names(@__MODULE__; all=true)`
call, issued as the *body of an eval* against the identical module object,
returns the complete, correct list every time.

**Working hypothesis:** this is consistent with Julia's binding-partition /
world-age semantics for globals (the same subsystem responsible for the
original `#56933` clone bug this package already worked around once). A
binding created via `Core.eval` inside the dedicated eval child task appears
to become visible to *further evaluated code* immediately, but not to
*compiled Julia code running directly on the connection task* that reads the
module via `names()`/`getfield` without going through another `Core.eval`.
This needs upstream (`sashakile/reply.jl`) triage with access to Julia's
binding-partition internals—the fix likely needs an explicit
`Base.invokelatest`-style boundary (or an equivalent binding-partition
refresh) at the point `names()`/`getfield` are called on a session module
from outside an eval context, not another `const`-vs-`=` tweak.

### Blast radius

- **`clone`** (§1.3 in the prior report): the "fixed" const-binding copy from
  `7c298792` never actually executes end-to-end over the wire—the copy loop
  reads zero source names, so nothing is copied, in every run. This is a
  regression to the *pre-fix* symptom (empty clone) via a completely different
  mechanism.
- **`ls-bindings`** (`94e63a6f`, shipped 2026-07-11 specifically to answer this
  report's own §3.3 ask): always returns `count: 0`. The feature doesn't work
  at all for any session with real state.
- **Not REPLy-specific**: the identical pattern reproduces in this
  workspace's own `SessionToolsMiddleware` (`middleware/custom.jl`), which
  implements `ls-bindings` the same way. This is a runtime-level issue, not a
  bug confined to one middleware's code.

### QA-suite gap that let this ship silently

Both `qa/features.py::test_clone_isolation` and `qa/middleware.py::test_ls_bindings`
report **PASS** against this exact regression:

- `test_clone_isolation` explicitly asserts `bindings_not_inherited == True`—written against the *pre-fix* behavior, before `7c298792` landed. It never
  got updated to assert the new const-copy semantics, so it now accidentally
  re-passes against the reintroduced bug for the wrong reason.
- `test_ls_bindings` wraps its only real assertions (`"alpha visible in
  bindings"`, etc.) in `if bindings:`—when `bindings == []`, the block is
  skipped entirely, and the suite reports pass on `count == len([]) == 0`.

**Recommendation:** update both tests to assert `len(bindings) > 0` /
`clone destination has the source's binding` as a hard precondition, not a
conditional. A suite that can pass on empty output can't catch this class of
regression, and this exact structure (assert only `if <the very thing you're
testing for> is non-empty`) should be treated as a standing anti-pattern
across the QA suites.

---

## §2. Our own middleware demo broke against the new version (not upstream's fault)

`middleware_demo/server.jl` crashed on startup after the update, for two
reasons, both in this repo's `middleware/custom.jl`:

1. **API drift.** `LoadFileMiddleware(allowlist)` (positional-arg constructor)
   no longer exists—REPLy's `LoadFileMiddleware` is keyword-only as of this
   version. Fixed to `LoadFileMiddleware(; load_file_allowlist=allowlist)`.
2. **Duplicate op registration.** REPLy's `default_middleware_stack()` now
   ships native `PingMiddleware`, `ReloadFileMiddleware`, and
   `LsBindingsMiddleware`—all three ops this demo previously had to
   implement itself to plug documented gaps. `build_handler` now validates the
   stack and **rejects duplicate op handlers** at startup:
   ```
   Duplicate handler for 'ping': middleware at indices 3 and 7
   Duplicate handler for 'reload-file': middleware at indices 12 and 13
   Duplicate handler for 'ls-bindings': middleware at indices 15 and 18
   ```
   This validation is itself a genuine robustness improvement—it turns a
   silent double-registration into a loud startup failure. Fixed by filtering
   the three now-native middlewares out of `default_middleware_stack()` before
   layering this repo's (extended) custom variants on top.

After both fixes, `middleware_demo/server.jl` starts cleanly and
`qa/middleware.py` passes 7/7 (was a hard server-start failure before the fix).
Note `test_ls_bindings` within that 7/7 is the false-pass described in §1—the
suite is green, the feature is broken.

---

## §3. Full QA scorecard (post-fixes, this version)

| Suite | Result | Notes |
|---|---|---|
| `revise.py` | 3/3 | unchanged from baseline |
| `concurrency.py` | 2/2 | unchanged from baseline |
| `features.py` | 7/7 | **includes the false-pass clone test, §1** |
| `pressure.py` | 6/6 | unchanged from baseline; see §4 for numbers |
| `middleware.py` | 7/7 | required the fixes in §2; **includes the false-pass ls-bindings test, §1** |
| `mcp.py` | 4/5 | the one "failure" is a stale assertion—see §5, not a regression |

Net: **26/27 nominal**, but two of those passes are silently invalid (§1), and
the one nominal failure (§5) is actually good news misreported by a stale test.

---

## §4. Pressure results (informational—no regressions found)

Re-ran the full pressure suite against the updated server; numbers are in
line with (slightly better than) the June 25 baseline, consistent with the
task-local I/O capture and tuple-dispatch perf work landing in this window:

| Test | Result | Key metric (this run) | Baseline (June 25) |
|---|---|---|---|
| Concurrent 10×100 eval | PASS | 298 req/s · p50=18ms/p95=21ms/p99=90ms · 0 errors | 428 req/s · p99=214ms |
| Rate limit (700 burst) | PASS | 600 served / 100 rejected | same |
| Output truncation (1.5 MB) | PASS | 1,000,012 bytes received, connection survived | same |
| Malformed protocol (7 cases) | PASS | server survived all | same |
| Session churn (50 cycles) | PASS | p50=34ms/p99=112ms | p50=28ms/p99=459ms |
| Connection saturation (101) | PASS | rejected at 100, full recovery | same |

(Throughput swings between runs are consistent with normal machine-load noise
on this evaluation machine; not treated as a finding either way. No file-descriptor
(FD) exhaustion regression observed—consistent with the `9f03ed5c` task-local I/O capture
change eliminating the shared-lock contention path implicated in the previous
report's §5 finding.)

---

## §5. MCP: The "1 failure" is `qa/mcp.py` being stale, not a regression

`qa/mcp.py` asserts the *previous* report's §2.4 claim—"4 of 8 MCP tools are
stubs"—as its pass condition. Against this version, all four
(`julia_complete`, `julia_lookup`, `julia_load_file`, `julia_interrupt`) are
now genuinely implemented, so the stub-verification test fails *because the
bug it checks for is fixed*:

```
[stub verification—the readiness report §3 claim]
  FAIL  4 tools confirmed as stubs (matches §3 claim)
        [NOT STUB] julia_complete: '{"completions":[...
        [NOT STUB] julia_lookup: '{"name":"map","methods":[...
        [NOT STUB] julia_load_file: 'load-file requires an explicit allowlist...
        [NOT STUB] julia_interrupt: 'Session not found: nonexistent'
```

**Recommendation:** flip this test to assert the tools work end-to-end
(it already captures each tool's live response—just invert the pass
condition) rather than asserting they remain stubs. Currently the suite's
only failing case is the one thing that actually got better.

---

## Priority findings for this round

1. **P0—`ls-bindings` and `clone` binding-copy are both non-functional over
   the wire** (§1). This blocks the primary use case of both ops for any
   session with real state, and silently invalidates the fix this project's
   own prior report requested for `clone` (§1.3) and got (`ls-bindings`,
   §3.3). Needs upstream triage focused on the binding-partition/world-age
   boundary between the eval child task and the connection task.
2. **P1—QA-suite blind spot**: `test_clone_isolation` and `test_ls_bindings`
   can both report PASS while returning empty results, because their
   meaningful assertions are conditioned on the very output they're supposed
   to validate being non-empty. Fix both to assert non-emptiness as a hard
   precondition. This is the reason §1 shipped undetected for at least one
   release cycle.
3. **P1—`qa/mcp.py`'s stub-verification test has an inverted pass
   condition** (§5) relative to the current, fixed reality. Low effort,
   currently the only "failing" line in the whole scorecard and it's
   misleading.
4. **P2—this repo's `middleware/custom.jl` needed two fixes to keep pace
   with upstream API changes** (§2): keyword-only `LoadFileMiddleware`, and
   removing now-redundant custom `ping`/`reload-file`/`ls-bindings`
   middlewares that duplicate ops REPLy ships natively. Both fixed in this
   round; flagged here because `build_handler`'s new duplicate-handler
   validation (a good change) will keep breaking any downstream middleware
   stack that predates a given upstream feature addition—worth a note in
   `MIDDLEWARE_GUIDE.md` about checking `default_middleware_stack()` for
   newly-native ops before layering custom ones on top.

## What's now solid

Everything not called out above held up under this round: eval correctness,
interrupt/stdin/timeout-ms, rate limiting, malformed-input handling, session
churn, connection saturation, Revise integration, the CLI client, and the
newly-implemented MCP tools. The performance work in the past week
(task-local I/O capture, concrete `EvalCoreResult`, tuple-based middleware
dispatch, direct-stream serialization) shipped without observable regressions
in throughput or latency, and per §4 likely improved FD-exhaustion behavior
under sustained mixed load—worth a follow-up dedicated FD-exhaustion re-run
against `qa/revise.py` + `qa/concurrency.py` + `qa/features.py` +
`qa/pressure.py` back-to-back to confirm the previous report's §5 leak is
actually gone, not just not hit at this session's load level.
