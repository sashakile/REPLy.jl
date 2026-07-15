# REPLy.jl—QA / UX / DX / AIX Round (2026-07-14, round 2)

**What is REPLy.jl?** A TCP/JSON-over-socket interactive Julia REPL server
(`github.com/sashakile/reply.jl`) used here for both human REPL work and
programmatic, agent-driven code evaluation. See
`REPLY_STRESS_REPORT_2026-07-14.md` (committed alongside this report) for a
fuller description and the protocol-level findings this report builds on.

**Terms used in this report:**
- **UX/DX** — User Experience / Developer Experience: how easy the tool is to
  install, invoke, and recover from errors with, evaluated here against
  standard CLI-usability categories (discoverability, conventions, output,
  errors, composability) rather than any tool-specific framework.
- **AIX** — AI (agent) Experience: the same questions, asked from the specific
  angle of an LLM agent driving REPLy programmatically rather than a human
  typing at a REPL, following on from the earlier
  `REPLY_AGENT_FIELD_REPORT.md` (a hands-on account of using REPLy
  as an agent's Julia execution substrate, also in this directory).
- **FD** — file descriptor.

**Date:** 2026-07-14
**Version:** 0.1.0 (`main`, commit `c1a8d8d`, tree-sha `c1e90dc3…`)—same build as
`REPLY_STRESS_REPORT_2026-07-14.md`
**Scope:** a second pass over the same version, widening from "does the protocol
hold up" to four angles: additional QA surface (sustained-load degradation,
retest of the previous FD-exhaustion finding), CLI interface UX/DX, and AIX
(the agent-experience angle from `REPLY_AGENT_FIELD_REPORT.md`, re-run against
what changed this version).

This round found one new P0 (sustained-load server degradation, a different
mechanism than the earlier FD-exhaustion finding) and one new P0 UX/DX finding
(the shipped CLI client can't run via any normal installation path). Both are
independent of the `clone`/`ls-bindings` regression already filed in the sibling
stress report.

---

## Part A—QA: Sustained-load degradation (distinct from the June 25 FD finding)

**Severity: Critical. Reproducible: 100%, deterministic, single connection load
pattern.**

The June 25 report's §5 flagged FD exhaustion (`dup: Bad file descriptor`) under
sustained mixed load across multiple QA suites on one long-lived server. That
specific error class appears to be gone—consistent with the task-local I/O
capture rewrite (`9f03ed5c`) replacing the dup2-based mechanism that produced it.

But the underlying category of bug—**a long-lived server degrades under
bursty concurrent load and stays degraded**—is still present, via a different
and more narrowly-isolated trigger:

### Repro

```
fresh server on :5557
  qa/concurrency.py --test max-concurrent   →  1/1 passed   (15 evals, 10 run, 5 rejected at the cap, as designed)
  qa/features.py                            →  3/7 passed   (was 7/7 on a fresh server)
```

Bisected against the two independent checks in `concurrency.py`:

| Prior step | `features.py` afterward |
|---|---|
| (nothing—fresh server) | 7/7 |
| `concurrency.py --test fifo` (8 concurrent evals, one session, under the cap) | 7/7—harmless |
| `concurrency.py --test max-concurrent` (15 evals across 15 sessions, 5 rejected by the `max_concurrent_evals=10` cap) | **3/7—degraded** |

The specific trigger is firing enough simultaneous evals to hit the
`max_concurrent_evals` cap and get some of them rejected with "Too many
concurrent evals." Isolated to just that one sub-test, on an otherwise-fresh
server, with nothing else run before or after it.

### What breaks, specifically

Re-running `qa/features.py` after the trigger:

```
[interrupt]  FAIL  eval terminated: False        (sleep(60)+interrupt no longer kills the eval)
[stdin]      FAIL  readline() got None            (stdin round-trip silently returns nothing)
[timeout-ms] FAIL  50ms on sleep(10) → timeout    (the timeout Timer no longer fires)
[silent]     FAIL  silent=true still emits stdout (output capture wiring broken)
```

Four independent mechanisms—interrupt delivery, stdin pipe feeding, timeout
timers, and I/O capture—all degrade together after the SAME trigger. Plain
`eval` keeps working throughout (the server never crashes or hangs; a follow-up
`1+1` always returns `2`). This points at a **shared piece of per-eval
infrastructure that the cap-rejection path fails to clean up**—the four
broken mechanisms are exactly the four things wired up per-eval in
`_run_eval_core`/`with_session_eval` (timeout `Timer`, dedicated child `Task`,
stdin `Pipe`+feeder task, `TaskCapturingIO` registration). The most likely
culprit is the 5 evals that get rejected by the cap check: if that path returns
early without unregistering/cleaning up whatever per-connection or per-process
state the four mechanisms share, five "half-started" eval contexts would be
left behind—matching the symptom (broken shared machinery, working plain
eval) far better than a full crash or hang would.

**Not self-healing:** waited 10s and retried—still 3/7. This is a permanent
degradation until the server process is restarted, not a transient race.

### Recommendation

Needs the same kind of upstream triage as the `clone`/`ls-bindings` finding:
instrument the cap-rejection branch in `EvalMiddleware` (the "Too many
concurrent evals" early-return) and check what it skips relative to the normal
completion path—specifically Timer cancellation, `register_active_eval!`/
`Threads.atomic_sub!(state.active_evals, ...)` bookkeeping, and stdin-feeder
teardown. A regression test that fires >10 concurrent evals to force
rejections, then exercises interrupt+stdin+timeout-ms on a *fresh* session
afterward, would catch this directly (the existing
`qa/revise.py`/`qa/concurrency.py`/`qa/features.py`/`qa/pressure.py`
back-to-back sequence in `qa/run_all.sh` happens to trigger it today only
because `run_all.sh` restarts the server between suites—so the suite
currently can't see this at all; it's only visible when suites intentionally
share one server, which `run_all.sh`'s own hygiene design prevents).

---

## Part B—UX/DX: The `replyc` CLI client

Per standard CLI heuristics: discoverability, conventions, output, errors,
composability (see the "Terms used in this report" note above).

### [CRITICAL] Discoverability/installation: `replyc` can't run via any normal install path

`replyc`'s own header comment says:

```
# Run it with the REPLy project environment so JSON3 is available, e.g.:
#   julia --project=/path/to/REPLy.jl bin/replyc eval '1 + 1'
```

Tried exactly that, plus the other path a real consumer would try:

| Invocation | Result |
|---|---|
| `julia --project=~/.julia/packages/REPLy/<hash> bin/replyc ...` (literally what the header documents) | **fails**: `Package JSON3 ... is required but doesn't seem to be installed`. A `Pkg.add`/git-dep-installed package's cache entry ships only `Project.toml`, never an instantiated `Manifest.toml`—this invocation can never work for any consumer who installed REPLy the normal way. |
| `julia --project=<your-own-project-that-depends-on-REPLy> bin/replyc ...` (the other obvious thing to try) | **fails**: `Package JSON3 not found in current path`. Julia's environment stacking only exposes a project's *direct* dependencies to top-level `using`; JSON3 is a transitive dependency of REPLy, not a direct one, in every project in this workspace (and in any typical consumer project—nobody directly depends on REPLy's own JSON library choice). |
| `julia --project=<a git clone of reply.jl, Pkg.instantiate()'d>` | **works.** This is the only path that succeeds. |

So the CLI client this project's own prior report asked for, and that upstream
shipped specifically to fix that ask, is **only reachable by cloning the
REPLy.jl source repository and running `Pkg.instantiate()` in it**—that is, the
contributor workflow, not the consumer workflow. Every user who installs REPLy
the way the README's own quick-start recommends (`Pkg.add` / git URL dep) hits
a dead end trying to use the CLI client the same README points them at.

**Fix options, cheapest first:**
1. Vendor a tiny standalone JSON encoder in `replyc` itself (it only needs to
   encode outgoing requests and decode simple line-delimited responses—this
   is a much smaller surface than general JSON3 usage) so it has zero external
   deps and runs with plain `julia bin/replyc ...`, no `--project` needed.
2. Ship `replyc` as `REPLy.main()`/`REPLy_jll`-style entry point invoked via
   `julia -e 'using REPLy; REPLy.replyc(ARGS)'`—since `using REPLy` from
   *any* consuming project already works (REPLy is a direct dep there), this
   sidesteps the transitive-JSON3 problem entirely without vendoring anything.
3. At minimum, document that `replyc` requires a source checkout, and correct
   the `--project=/path/to/REPLy.jl` example, which is actively misleading as
   written (it names a path that, for the vast majality of installs, will be
   a `Pkg` cache directory where the fix won't work).

### [MEDIUM] Spurious `nothing` echoed for every `println`-style eval

```
$ replyc eval --port 5557 'println("hi")'
hi
nothing
```

`replyc`'s `print_eval_responses` checks `!isnothing(msg["value"])` before
printing the value—but REPLy's wire protocol always sends `value` as a JSON
**string** repr (`"nothing"`, not JSON `null`), so this check can never filter
Julia's `nothing`; it only catches the case where REPLy itself sent literal
`null` (a `repr-error`, handled separately). The net effect: any eval whose
result is `nothing`—which is the common case for `println`, `for` loops,
`@info`, and most side-effecting agent-driven code—prints a spurious
trailing `nothing` line that a real Julia REPL would suppress. Low severity on
its own, but it directly undercuts the "quote-safe drop-in REPL feel" pitch,
and it will be the first thing anyone piping `println`-heavy scripts through
`replyc` notices.

**Fix:** compare against the string `"nothing"` (or have REPLy send a
`"value-is-nothing": true` flag / `null` rather than the string, mirroring the
existing `repr-error`/`null` convention for unrepresentable values).

### What worked well

- **Quoting robustness—the actual selling point—holds up.** Verified with
  `println("hello \"world\" with \$dollar and \\backslash")` through `replyc`:
  round-trips correctly (impossible with the README's own `nc` example). This
  is genuinely fixed, once the tool can run at all.
- **`session new|ls|rm`** all work correctly, including UUID/name round-tripping.
- **Error/exit-code conventions are sound**: connection-refused gives a clear
  `connection failed: ...` message (exit 1), an eval error prints the Julia
  error text to stderr (exit 1), an unknown subcommand prints usage to stderr
  (exit 2), `--help`/no-args print usage to stdout (exit 0). This maps cleanly
  onto standard CLI exit-code conventions (0 ok / 1 runtime error / 2 usage
  error) without the tool having to say so anywhere.

---

## Part C—AIX: What this means for agent use specifically

Revisiting `REPLY_AGENT_FIELD_REPORT.md`'s framing—REPLy as an LLM agent's
Julia execution substrate—against what changed this version:

- **The #1 recommendation from the field report was "loud session semantics";
  upstream shipped it** (`42550db0`, `"ephemeral": true` advisory flag on
  session-less eval). Verified present in this version's responses
  (`{'ephemeral': True, ...}` observed throughout this round's ad-hoc evals).
  This directly fixes the single biggest first-ten-minutes trip-hazard the
  field report identified.
- **The #2 recommendation ("`include` in session modules") also shipped and is
  verified working**—no more `Compiler.include` `UndefVarError` surprise.
- **But the new `ls-bindings` op—the single feature that would have made the
  field report's own workaround unnecessary** (`"eval → string.(names(@__MODULE__;
  all=true))"`) **doesn't work** (§1 of `REPLY_STRESS_REPORT_2026-07-14.md`,
  the sibling stress report committed alongside this one). An
  agent resuming a long-lived session still can't ask "what's defined here?"
  through the intended native path; it must fall back to the exact eval-based
  workaround the field report already documented as a stopgap, because that
  workaround (running `names()` *as eval code*) is the one code path that
  still sees the bindings correctly.
- **The CLI client gap the field report didn't test directly (it drove
  everything through `bin/repl-send.sh`, a workspace wrapper) is
  worse than "missing"—it's shipped-but-unreachable** (Part B). An agent
  following the README's own advice to use `replyc` instead of a bespoke
  wrapper will fail at the first invocation unless it happens to have cloned
  REPLy's source rather than depending on it normally—which isn't how any
  of the README's own quick-start instructions tell it to install REPLy.
- **Net effect for an agent bootstrapping fresh from the README today:** better
  first-ten-minutes experience than three weeks ago (loud ephemeral sessions,
  working `include`, soft-scope warnings gone, `if-exists=reuse` verified
  working for idempotent session setup)—but the two features specifically
  aimed at *this* audience (`ls-bindings`, `replyc`) don't deliver on their
  stated purpose yet, so an agent still ends up back on the same
  eval-string-scraping and hand-rolled-JSON-over-`nc` patterns the original
  field report used, just with better error messages along the way.

---

## Consolidated priority list (this round, combined with the sibling stress report)

| # | Finding | Severity | Where |
|---|---|---|---|
| 1 | `clone`/`ls-bindings` return empty results over the wire | Critical | `REPLY_STRESS_REPORT_2026-07-14.md` §1 |
| 2 | Server degrades permanently after `max_concurrent_evals` cap-rejection burst | Critical | Part A above |
| 3 | `replyc` can't run via any normal (`Pkg.add`) install path | Critical | Part B above |
| 4 | QA suites can PASS on empty/skipped assertions (masks #1) | High | `REPLY_STRESS_REPORT_2026-07-14.md` §1 |
| 5 | `qa/mcp.py` has an inverted pass condition (asserts tools are still stubs) | High | `REPLY_STRESS_REPORT_2026-07-14.md` §5 |
| 6 | `replyc` echoes spurious `nothing` for `println`-style evals | Medium | Part B above |
| 7 | `middleware/custom.jl` (this repo) needed two API-compat fixes | Medium | already fixed, see commit `35ae808` |

Findings 1–3 share a pattern worth calling out explicitly: **all three are in
code paths added or changed specifically to fix a gap this project's own
previous reports flagged** (clone's const-copy fix, the new `ls-bindings` op,
the new `replyc` CLI). None of the three received a QA check exercised the way
a real client would exercise it—through the actual wire/process boundary,
under the actual load pattern, via the actual install path—which is
precisely where each one breaks. The recommendation that generalizes across
all three: **when closing a gap raised by an external evaluation, add the
regression test in the same shape as the report that raised it** (wire-level
client, not `build_handler()` call; multi-suite-shared-server load, not
single-suite-fresh-server; `Pkg.add`-style install, not source checkout)—each of these bugs is invisible from the "easy" version of its own test.
