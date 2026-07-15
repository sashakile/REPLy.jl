# REPLy.jl—Release-Readiness Verdict (2026-07-14)

**What's REPLy.jl?** A TCP/JSON-over-socket interactive Julia REPL server
(`github.com/sashakile/reply.jl`). A client sends `{"op":"eval", "code":"..."}`
over a socket and gets back structured JSON responses (`value`, `out`, `err`,
`status`). It's built for both human REPL work from an editor and programmatic,
agent-driven code evaluation—persistent named sessions, interrupt, stdin,
file loading, and a Model Context Protocol (MCP) adapter for LLM tool-calling.

**Purpose of this document:** four evaluation reports have now been written
against this project from one evaluation workspace (three from this date, one from three
weeks earlier). Each has its own findings and priority list, but none of them
answers the one question a maintainer or adopter actually needs answered:
**is this ready to release?** This document synthesizes all four into a single
verdict. It's meant to stand alone—read this first if you only read one
document from this set.

**Source reports, in chronological order** (all committed alongside this one):
1. `REPLY_PUBLIC_READINESS_REPORT.md`—2026-06-25, commit-era tree-sha `f52f02f3…`. First
   evaluation: protocol correctness, pressure testing, nREPL feature-parity comparison.
2. `REPLY_STRESS_REPORT_2026-07-14.md`—protocol-level regression testing against
   the current build (`main`, commit `c1a8d8d`, tree-sha `c1e90dc3…`, ~40 commits
   after the June 25 build).
3. `REPLY_QA_UX_DX_AIX_REPORT_2026-07-14.md`—sustained-load behavior, CLI
   client usability, and agent-experience testing against the same build.
4. `REPLY_SPEC_FIDELITY_AUDIT_2026-07-14.md`—checked the live server against
   every checkable requirement in this project's own `openspec/specs/security/spec.md`
   and `resource-limits/spec.md`.

---

## Verdict

**Not ready for a general-public or production release. Solid and improving
fast for an expert audience willing to read the source and route around
known rough edges.**

This is a real judgment call, not a simple pass/fail—the evidence pulls in
both directions, and both directions matter.

---

## What argues for "ready"

- **Core correctness is genuinely strong.** Eval, interrupt, stdin, timeout-ms,
  rate limiting, malformed-input handling, and connection saturation all held
  up under real pressure testing in both the June 25 and July 14 rounds
  (`REPLY_PUBLIC_READINESS_REPORT.md` §5, `REPLY_STRESS_REPORT_2026-07-14.md` §4).
- **Development velocity and responsiveness are excellent.** Nearly every P0/P1
  finding from the June 25 report—no CLI client, broken `include` in
  sessions, undocumented server modes, four stubbed MCP tools, no `ping` op—got a real fix within three weeks (`REPLY_STRESS_REPORT_2026-07-14.md`,
  "What changed upstream since the last report").
- **At least one previously-identified race condition is genuinely fixed.**
  The eval-timeout/manual-interrupt collision the security spec calls out was
  stress-tested directly (20 trials at the exact race boundary, 0 bleed-throughs—`REPLY_SPEC_FIDELITY_AUDIT_2026-07-14.md` §5) and looks solid.
- **The protocol design itself hasn't needed to change.** Self-describing
  `describe` op, structured errors, clean JSON framing—these were sound in
  June and remain sound now.

## What argues for "not ready," and why it outweighs the above

1. **The features meant to make it broadly usable are the ones currently
   broken.** `clone` and `ls-bindings` were shipped specifically to answer this
   evaluation's own prior asks (`REPLY_PUBLIC_READINESS_REPORT.md` §1.3 and §3.3)—and both return empty results over the wire, 100% reproducible, in a
   vanilla `REPLy.serve()` with no custom code
   (`REPLY_STRESS_REPORT_2026-07-14.md` §1). The CLI client (`replyc`), also
   shipped to answer this evaluation's own prior ask (§1.1), can't run via any
   normal `Pkg.add`-style install
   (`REPLY_QA_UX_DX_AIX_REPORT_2026-07-14.md` Part B). A newcomer following the
   README today hits a *worse* first impression on these three specific fronts
   than someone who used the raw `nc` workaround the README showed three weeks
   ago—the exact three gaps the last evaluation flagged as most blocking are,
   in a real sense, still blocking, just with more sophisticated-looking (but
   non-functional) fixes now sitting on top of them.

2. **The recommended production deployment mode has a real reliability gap
   with no mitigation.** The README recommends a long-running background
   server (`julia server.jl &`). A client burst that exceeds
   `max_concurrent_evals` leaves that server *permanently* degraded—interrupt,
   stdin, and timeout machinery all break together, with no self-heal short of
   a restart (`REPLY_QA_UX_DX_AIX_REPORT_2026-07-14.md` Part A). The two
   mechanisms that would limit blast radius on a long-lived server—idle-session
   expiry and audit logging—are fully built and unit-tested in the codebase,
   and never wired into the server anyone actually starts
   (`REPLY_SPEC_FIDELITY_AUDIT_2026-07-14.md` §1). This isn't "a feature is
   missing"—it's "the safety net exists in the repository but isn't attached
   to the product."

3. **The project's own specification can't currently be trusted to configure
   the server correctly.** Four `ResourceLimits` defaults are off from their
   documented values by 2×–10× (eval timeout: 30s in code vs. 60s in the spec;
   message size cap: 1 MB vs. 10 MB documented; and two more), and three
   documented limits (`max_memory_mb`, `session_idle_timeout_s`,
   `min_rate_limit_per_min`) have no enforcement code anywhere
   (`REPLY_SPEC_FIDELITY_AUDIT_2026-07-14.md` §2). Anyone deciding this is
   production-ready by reading the docs—including an AI agent, since this
   project's own `AGENTS.md` instructs agents to treat these specs as
   authoritative—is working from wrong numbers.

## The pattern that matters more than any single bug

Three separate gaps—idle-session sweep, audit logging, `max_concurrent_evals`
queueing—all share the same shape: **correctly built, unit-tested in
isolation, never wired into the actual server entry point**
(`REPLY_SPEC_FIDELITY_AUDIT_2026-07-14.md` §1 and §3). That's not three
unrelated bugs; it's one process gap—nothing currently checks that
`default_middleware_stack()`/`serve()` actually calls what the spec and the
unit tests assume it calls. A process gap like this doesn't resolve itself by
fixing the three known instances; it will keep producing the same failure mode
on the next three features unless something structural changes (the
spec-fidelity audit's closing recommendation—a test that diffs
`ResourceLimits`'s fields against the spec's table, and one that asserts every
exported middleware is reachable from the default stack—is the fix for the
*pattern*, not just the instances).

Similarly, `qa/features.py`'s `clone` test and `qa/middleware.py`'s
`ls-bindings` test both currently report **PASS** against the exact regressions
described above, because their real assertions are conditioned on the very
output they're meant to be checking being non-empty
(`REPLY_STRESS_REPORT_2026-07-14.md` §1, "QA-suite gap that let this ship
silently"). A green test suite isn't currently strong evidence that these two
features work.

---

## What "ready" would look like

A short, concrete gating list, all independently actionable and none of them
architecturally hard per the audits above:

1. Fix `clone` and `ls-bindings` returning empty results over the wire
   (`REPLY_STRESS_REPORT_2026-07-14.md` §1)—likely needs upstream Julia
   binding-partition/world-age triage, not just another retry of the same fix shape.
2. Fix the permanent server degradation after a `max_concurrent_evals`
   cap-rejection burst (`REPLY_QA_UX_DX_AIX_REPORT_2026-07-14.md` Part A)—plausibly the same root cause as building the spec-mandated eval queue
   (`REPLY_SPEC_FIDELITY_AUDIT_2026-07-14.md` §3), so these two fixes may be one fix.
3. Either wire `AuditMiddleware` and `sweep_idle_sessions!` into `serve()`, or
   explicitly cut them from the security/session-management specs as
   post-v1.0—but stop leaving a `SHALL` requirement in the spec for a
   capability the shipped server doesn't have (`REPLY_SPEC_FIDELITY_AUDIT_2026-07-14.md` §1).
4. Fix `replyc`'s packaging so it runs via a normal dependency install, not
   only a source checkout (`REPLY_QA_UX_DX_AIX_REPORT_2026-07-14.md` Part B).
5. Reconcile `ResourceLimits`'s actual field names/defaults with
   `resource-limits/spec.md`'s table (`REPLY_SPEC_FIDELITY_AUDIT_2026-07-14.md` §2).
6. Fix the two QA-suite tests that can pass on empty output
   (`REPLY_STRESS_REPORT_2026-07-14.md` §1) and the one with an inverted pass
   condition (`REPLY_STRESS_REPORT_2026-07-14.md` §5)—not release-blocking on
   their own, but without them the other five items can regress silently again.

None of these look like a multi-month effort individually. Given the
three-week turnaround on the last set of fixes, this is plausibly a few weeks
of focused work away from a real v1.0—but as of this build, the release-readiness
gaps are concentrated in exactly the areas—broad usability and long-running
reliability—that a "1.0" label promises.
