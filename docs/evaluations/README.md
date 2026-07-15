# REPLy.jl — Evaluation Reports

Independent evaluation reports covering protocol correctness, sustained-load
behavior, spec fidelity, UX/DX/AIX, and release readiness. Produced by dogfooding
REPLy to drive real Julia projects.

## 2026-07-14 round (current)

| Document | Scope | Key findings |
|---|---|---|
| [`REPLY_STRESS_REPORT_2026-07-14.md`](REPLY_STRESS_REPORT_2026-07-14.md) | Protocol regression testing against `main` (commit `c1a8d8d`) | P0: `ls-bindings`/`clone` return empty over the wire; QA false passes; server degrades after cap burst |
| [`REPLY_QA_UX_DX_AIX_REPORT_2026-07-14.md`](REPLY_QA_UX_DX_AIX_REPORT_2026-07-14.md) | Sustained load, CLI client usability, agent experience | P0: permanent server degradation after `max_concurrent_evals` rejection; P0: `replyc` unreachable via `Pkg.add` |
| [`REPLY_SPEC_FIDELITY_AUDIT_2026-07-14.md`](REPLY_SPEC_FIDELITY_AUDIT_2026-07-14.md) | Live server vs. `openspec/specs/*/spec.md` requirements | P0: `AuditMiddleware`/`sweep_idle_sessions!` dead code; 4 `ResourceLimits` defaults wrong by 2–10× |
| [`REPLY_RELEASE_READINESS_VERDICT_2026-07-14.md`](REPLY_RELEASE_READINESS_VERDICT_2026-07-14.md) | Synthesis of all four reports into a single verdict | Not ready for general-public release; 6-item gating list |

## 2026-06-25 round (baseline)

| Document | Scope |
|---|---|
| [`REPLY_PUBLIC_READINESS_REPORT.md`](REPLY_PUBLIC_READINESS_REPORT.md) | First evaluation: protocol correctness, pressure testing, nREPL comparison |
| [`REPLY_USAGE_REPORT.md`](REPLY_USAGE_REPORT.md) | Hands-on usage findings |
| [`REPLY_AGENT_FIELD_REPORT.md`](REPLY_AGENT_FIELD_REPORT.md) | Agent-experience perspective |

## Reference

| Document | Scope |
|---|---|
| [`MIDDLEWARE_GUIDE.md`](MIDDLEWARE_GUIDE.md) | How to build custom middleware |
