# REPLy.jl — Report from Agent Usage (XAct.jl review session)

A field report on **REPLy.jl** as an agent-driving tool, based on using it end-to-end
to review XAct.jl. Distinct from the existing `REPLY_USAGE_REPORT.md` /
`REPLY_PUBLIC_READINESS_REPORT.md`: this is the *hands-on experience* of an LLM agent
using REPLy as its Julia execution substrate over ~150 evals.

Environment: REPLy (git-tree-sha1 `f52f02f`, repo `sashakile/reply.jl`, branch `main`),
Julia 1.12.6, macOS/aarch64. Server on `:5559`, project `xact-trial/`, one named session.

---

## What I used it for

I ran a Julia server once (`julia --project=. server.jl 5559`), created **one named
session**, loaded `XAct` into it, and then drove the entire multi-hour review through
that session via `bin/repl-send.sh 5559 -s <uuid>` (inline code and `-f file`). Session
state — the loaded package, manifold/metric/tensor definitions — persisted across every
call.

## The core win: persistence kills cold-start tax

This is the headline benefit and it is large.

| Path | First call | Subsequent calls |
|---|---|---|
| Cold `julia --project=. -e '…'` (what I'd otherwise do) | ~30 s (load + precompile XAct) | ~30 s **every time** |
| REPLy persistent session | ~1.4 s (one-time `using XAct`) | **~0.4 s** |

Every probe, fuzz input, and test-file run reused a warm session. For an
exploration that made ~150 evaluations, this is the difference between minutes
and hours. It also let me **accumulate state** — define a manifold once, then run
dozens of `ToCanonical`/`Contract` probes against it — which matches how a human
would use a REPL and is impossible with one-shot `julia -e`.

## What worked well

- **Self-describing protocol.** `describe` returns the full op catalog with
  `requires`/`doc`/`returns`. I could discover the API without reading source.
- **Rich op surface.** Beyond `eval`: `complete` (tab-completion — it correctly
  completed `ToCanon`→`ToCanonical` *from the session's `using XAct`*), `lookup`
  (docs+methods for documented symbols), `load-file`, `interrupt`, `stdin`,
  `clone`, `ls-sessions`, `new-session`, `close`.
- **Clean JSON-over-TCP framing.** The `repl-send.sh` wrapper JSON-encodes in
  Python, so arbitrary Julia — quotes, `$`, newlines, multi-line blocks — passes
  through with zero shell-escaping pain. This mattered constantly (tensor strings
  are full of `[`, `-`, `"`).
- **Structured errors.** Failures come back as `{"err": …, "status":["done","error"]}`
  with full stack traces, so I could distinguish "my bug" from "library bug"
  cleanly (crucial when hunting XAct defects).
- **In-session tooling.** `@elapsed`, `methods()`, `repr()`, `@testset`, and
  `sprint(showerror, e)` all worked, so I could benchmark and introspect without
  leaving the session.
- **Stability.** The server stayed up and responsive for the entire session with
  no restarts, leaks, or degradation.

## Friction points (with root causes)

These are real UX papercuts I hit, roughly in order of time lost:

1. **Silent ephemeral sessions without `-s`.** A request with no `session` field
   gets a *fresh, throwaway* session module each time (`Main.var"##REPLySession#…"`).
   My `using XAct` in one call was invisible to the next. Nothing warned me — the
   second call just failed with `UndefVarError`. **Fix idea:** when a client sends
   `eval` with no session, either warn in the response, or default to a stable
   "primary" session. This is the single biggest trip-hazard for a new user/agent.

2. **Session identity is a UUID, not the name you pass.** I tried `-s xact` and got
   `Session not found: xact`. Sessions are created by `new-session` (returns a UUID);
   `-s` then needs that UUID. `describe` shows `new-session` takes an *optional name*
   and `close` accepts "UUID **or name alias**", so name-aliasing exists — but it
   wasn't obvious that I had to *register* the name first. **Fix idea:** make
   `eval` with an unknown `session` name auto-create it (opt-in), or document the
   name-alias path prominently.

3. **Named sessions eval in a submodule, not `Main`.** Code runs in
   `Main.var"##REPLyNamedSession#…"`. Two concrete consequences bit me:
   - `Main.eval(:(X = 0))` set the global in `Main`, invisible to the session.
   - `include("file.jl")` failed: `include` isn't defined in the session module.
     (I had to use `load-file` / `-f` instead, which *does* work.)
   This is defensible isolation, but the `include` gap is surprising since it's the
   reflex for running a test file. **Fix idea:** inject an `include` bound to the
   session module, or document `load-file` as the substitute.

4. **Soft-scope warnings on multi-line blocks.** Top-level `x = …; x += 1` inside a
   multi-line eval triggers Julia's soft-scope ambiguity warning (as at the REPL).
   Non-fatal, but noisy in output and briefly made me suspect double-execution.
   I verified (with a counter) that blocks execute **exactly once** — the warning
   was a false alarm. **Fix idea:** wrap eval bodies so top-level assignments use
   REPL-style soft-scope semantics silently, matching interactive expectations.

5. **`lookup` misses `using`-imported symbols.** `lookup` returned full docs for
   `println` (Base) but `found:false` for `reset_state!` (an XAct export live in the
   session via `using`). Completion *found* it; doc-lookup didn't. Minor inconsistency
   between the two introspection ops.

None of these are correctness bugs — REPLy computed everything correctly. They're
discoverability/ergonomics issues, and (1)+(2) together account for nearly all the
confusion I had in the first ten minutes.

## Observations for agent use specifically

- REPLy is an **excellent agent substrate**: warm state + structured errors +
  self-description are exactly what an autonomous agent needs to explore a library
  efficiently. The persistence alone changed what was feasible in the time budget.
- The friction points cluster around **implicit session semantics**. An agent
  benefits from *explicit, loud* defaults; REPLy currently favors silent isolation.
  A "you are in an ephemeral session; state won't persist" hint on session-less
  `eval` would save every first-time agent the exact confusion I hit.
- `describe` + `complete` make REPLy **introspectable enough to bootstrap without
  docs** — I discovered `load-file`, `clone`, and the op schemas purely from the wire.

## Recommendations (prioritized)

1. **Loud session semantics.** On `eval` without `session`, return an advisory
   flag (`"ephemeral": true`) or a one-time note. Highest-leverage UX fix.
2. **`include` in session modules** (or document `load-file` as the canonical
   file-runner in the README's quick-start).
3. **Reconcile `lookup` with `using`** so documented, imported symbols resolve.
4. **Suppress/relabel soft-scope warnings** for top-level eval bodies.
5. Keep the self-describing protocol and JSON framing exactly as they are — they
   are the best parts.

## Verdict

REPLy did its job invisibly well once past the session-identity learning curve.
The correctness was flawless, the performance benefit decisive, and the protocol
genuinely pleasant to drive programmatically. The improvements worth making are all
about **making implicit session behavior explicit** — a small amount of loudness
would eliminate essentially all the friction an agent encounters.
