---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

#+title: Failure Handling and Recovery Semantics Review: REPLy.jl (REPLy_jl-umg.7)
#+date: 2026-04-29

* Executive Summary

This pass reviewed failure handling in REPLy.jl across:
- transport and connection handling
- protocol parsing and request validation
- eval, interrupt, and load-file middleware
- shutdown behavior
- audit logging surface

It applies the =error-handling-diagnostician= lens for detection/classification/communication/recovery/learning and a lightweight =verification-diagnostician= lens to check whether the implemented behavior and nearby claims are internally consistent.

Overall verdict:
- REPLy.jl has a *real error model*, not just generic catch-all handling. Validation errors, unknown ops, missing sessions, timeouts, interrupts, oversize payloads, rate limits, and internal exceptions are all represented distinctly at the wire level in at least some paths.
- The strongest parts are *protocol validation*, *transport survival after handler exceptions*, *structured eval exception payloads*, and *idempotent interrupt semantics*.
- The weakest parts are *cross-path consistency*, *observability/learning hooks*, and *recovery semantics for partial or boundary failures*. Several failure paths produce different shapes or metadata for semantically similar conditions, and the audit subsystem exists largely in isolation from runtime failure handling.

Primary result categories:
- Failure classes catalogued: 11
- Confirmed strengths: 8
- Material inconsistencies / gaps: 10
- Highest-risk findings: 4

* Evaluation Summary

Artifact: REPLy failure-handling paths in =src/errors.jl=, =src/protocol/message.jl=, =src/middleware/eval.jl=, =src/middleware/interrupt.jl=, =src/middleware/load_file.jl=, =src/transport/tcp.jl=, =src/server.jl=, =src/security/audit.jl=
Artifact Type: code
Operating Context: internal interactive service / local high-availability-ish developer infrastructure
Primary Boundary Reviewed: transport -> protocol -> middleware -> shutdown
Governance Referenced: project AGENTS + tests only; no separate SLO/runbook standard found

Dimension Scores:
- Failure Model:     *ADEQUATE*
- Boundary/Contract: *WEAK*
- Recovery Design:   *ADEQUATE*
- Communication:     *WEAK*
- Learning Loop:     *DEFICIENT*

Overall Verdict: *NEEDS_REWORK*

Why not merely revision:
- no integrated learning/observability loop is attached to runtime failures
- similar failure classes use inconsistent response shapes/metadata across paths
- some boundary failures silently degrade to connection close or operator-invisible behavior without any structured runtime record

* Files Reviewed

Implementation:
- =src/errors.jl=
- =src/protocol/message.jl=
- =src/middleware/eval.jl=
- =src/middleware/interrupt.jl=
- =src/middleware/load_file.jl=
- =src/transport/tcp.jl=
- =src/server.jl=
- =src/security/audit.jl=

Tests:
- =test/unit/error_test.jl=
- =test/unit/message_test.jl=
- =test/unit/interrupt_middleware_test.jl=
- =test/unit/load_file_middleware_test.jl=
- =test/unit/resource_enforcement_test.jl=
- =test/unit/eval_option_compliance_test.jl=
- =test/unit/eval_middleware_test.jl=
- =test/unit/disconnect_cleanup_test.jl=
- =test/unit/audit_log_test.jl=
- =test/e2e/eval_test.jl=

* Failure Taxonomy

| Failure Class | Detection Point | Wire Classification | Recovery / Outcome |
|-
| Invalid JSON / partial read / disconnect | =receive= in =src/protocol/message.jl= | no protocol response; treated as closed boundary | stop processing connection |
| Oversized message | =receive= throws =MessageTooLargeError=; caught in =handle_client!= | =status:[done,error]= with size message | send one error, then close connection |
| Request validation error | =validate_request= | =status:[done,error]=, flat error text | reject request, keep connection alive |
| Unknown op | =UnknownOpMiddleware= | =status:[done,error,unknown-op]= | reject request, keep connection alive |
| Session-not-found | shared helper in =src/errors.jl= | =status:[done,error,session-not-found]= | reject request, keep connection alive |
| Rate limit exceeded | =handle_client!= | =status:[done,error,rate-limited]= | reject request, keep connection alive, continue serving later requests |
| Concurrent eval limit exceeded | =eval_responses= | =status:[done,error,concurrency-limit-reached]= | reject request |
| Session limit exceeded | =SessionMiddleware=/=SessionOpsMiddleware= | =status:[done,error,session-limit-reached]= | reject request |
| Eval/runtime/parse/load-file execution error | =_run_eval_core= / =_run_load_file_core= | =status:[done,error]= plus =err/ex/stacktrace= | request fails; session usually remains usable |
| Timeout | timer path in =eval_responses= | =status:[done,error,timeout]= | interrupt eval, return terminal timeout |
| Interrupt | =InterruptMiddleware= / eval catch path | non-terminal interrupt request returns success metadata; eval terminal is =status:[done,interrupted]= | cooperative cancellation; session remains reusable |

* Recovery Matrix

| Failure class | Current handling | Risk | Recommended handling |
|-
| Malformed JSON | silent close, no response | Medium | keep silent-close if desired, but add audit/metric hook |
| Oversized message | one error then disconnect | Low | good default; add audit hook |
| Validation failure | structured request-local error | Low | keep; consider stable machine error codes |
| Unknown op | structured error + status flag | Low | keep |
| Internal handler exception | converted to structured internal error, connection survives | Low | keep; consider dedicated internal-error code |
| Rate limit | structured error, connection survives | Low | keep; add observability |
| Eval runtime error | structured ex/stacktrace | Medium | decide exposure policy for stacktrace in all deployments |
| Timeout | terminal timeout response | Medium | keep; make timeout shape consistent with other error helpers |
| Interrupt | idempotent success + interrupted terminal on eval | Low | keep |
| Load-file read failure | plain error string only | Medium | normalize shape / status details |
| Shutdown interruption | active evals scheduled with InterruptException and sockets closed after grace | Medium | add observability / explicit shutdown result accounting |

* Confirmed Strengths

** Strength 1 — Request validation failures are cleanly isolated from execution failures
- Evidence: =validate_request= in =src/protocol/message.jl=
- Behavior:
  - invalid id/op/key shape is rejected before middleware dispatch
  - connection remains alive for subsequent requests
- Tests:
  - =test/unit/message_test.jl=
  - =test/unit/error_test.jl=

** Strength 2 — Transport-layer handler exceptions are converted into protocol-safe responses
- Evidence:
  - =handle_client!= wraps handler(msg) in try/catch and uses =internal_error_response=
- Recovery:
  - request fails but connection survives
- Tests:
  - =test/unit/message_test.jl=
  - =test/e2e/eval_test.jl=

** Strength 3 — Runtime eval failures communicate rich structured data
- Evidence:
  - =error_response(...; ex, bt)= includes =err=, =ex.type=, =ex.message=, =stacktrace=
  - =eval_error_response= reuses shared shape
- Tests:
  - =test/unit/error_test.jl=

** Strength 4 — Interrupts are modeled distinctly from errors
- Evidence:
  - =InterruptMiddleware= returns success metadata for the interrupt request itself
  - eval terminal path uses =status:[done,interrupted]= without =error=
- Tests:
  - =test/unit/interrupt_middleware_test.jl=

** Strength 5 — Timeout has explicit precedence over interrupt in eval terminal handling
- Evidence:
  - timeout path rewrites interrupted terminal to =done,error,timeout=
- Tests:
  - =test/unit/eval_middleware_test.jl=

** Strength 6 — Closed-channel response send failures do not crash the server
- Evidence:
  - =handle_client!= treats connection-closed send errors as normal return
- Tests:
  - =test/unit/disconnect_cleanup_test.jl=
  - =test/e2e/eval_test.jl= disconnect scenario

** Strength 7 — Rate limit and message size failures are enforced at the transport boundary
- Evidence:
  - =handle_client!= handles both before application logic runs
- Why this is good:
  - avoids pushing abusive traffic deeper into the stack

** Strength 8 — Sessions usually recover after failure
- Evidence:
  - timeout leaves named session reusable
  - interrupt leaves named session reusable
  - runtime eval errors do not poison future requests by default
- Tests:
  - =test/unit/eval_middleware_test.jl=
  - =test/unit/interrupt_middleware_test.jl=

* Findings

** [EHD-1.1] [HIGH] =src/security/audit.jl= / runtime integration
- Dimension: Learning Loop
- Gap: an audit subsystem exists, but no reviewed runtime path actually records malformed input, oversized messages, rate limits, internal exceptions, timeouts, shutdown interrupts, or load-file denials into it.
- Impact: the system has almost no built-in memory of failures. Operator learning, incident reconstruction, and abuse analysis depend on external observation only.
- Evidence:
  - =record_audit!= exists and is tested in isolation
  - repository search found no runtime call sites using it
- Remediation:
  - define which failures must emit audit entries and at what boundary
  - at minimum: oversize payloads, rate limits, path denials, shutdown interrupts, internal exceptions

** [EHD-2.1] [HIGH] =src/middleware/eval.jl= vs =src/errors.jl=
- Dimension: Boundary/Contract
- Gap: semantically similar failures use inconsistent wire shapes.
- Impact: clients must special-case more paths than necessary; downstream tooling cannot classify failures uniformly.
- Evidence:
  - runtime eval errors use shared =error_response= with =ex= and =stacktrace=
  - timeout uses hand-built =response_message(... "status" => ["done","error","timeout"], "err" => ...)= and omits =ex/
stacktrace=
  - interrupt terminal uses hand-built =response_message= rather than shared helper
  - module-resolution failure uses plain =error_response= without specific status flag
- Remediation:
  - decide a canonical error schema strategy: which fields are mandatory, optional, and prohibited for validation vs execution vs timeout conditions

** [EHD-2.2] [HIGH] =src/middleware/load_file.jl=
- Dimension: Boundary/Contract
- Gap: load-file read failures are communicated as plain text only, while evaluation failures from the loaded file get structured exception metadata.
- Impact: two failures in the same operation class (“load-file failed”) expose different machine semantics.
- Evidence:
  - read failure path: =error_response(request_id, "Failed to read file: ...")=
  - eval failure path: =eval_error_response(...; bt=...)= with =ex/stacktrace=
- Remediation:
  - separate I/O failure, allowlist denial, parse/runtime execution failure into explicit machine classes/status flags or subcodes

** [EHD-2.3] [HIGH] =src/protocol/message.jl:receive=
- Dimension: Communication
- Gap: malformed JSON and partial-read failures are intentionally silent to the client and leave no internal structured record in the reviewed code.
- Impact: producers of malformed traffic receive no actionable feedback, and operators cannot distinguish benign disconnect churn from parser abuse using built-in signals.
- Evidence:
  - malformed JSON returns =nothing=
  - =handle_client!= treats =nothing= as normal termination
- Remediation:
  - if silent close remains desired, add at least an audit/metric counter
  - consider bounded malformed-message counting if abuse resistance matters

** [EHD-2.4] [MEDIUM] =src/transport/tcp.jl:handle_client!=
- Dimension: Boundary/Contract
- Gap: oversize-message failure uses empty request ID even when the line may contain one, while rate-limited and handler failures attempt best-effort request-id recovery.
- Impact: correlation behavior differs across boundary failures.
- Evidence:
  - oversize path always sends =error_response("", ...)=
  - other transport errors use =safe_request_id(msg)=
- Remediation:
  - document that oversized messages are uncorrelated by design, or add a framing-level policy for correlation if safe

** [EHD-3.1] [HIGH] =src/middleware/eval.jl= early module-resolution path
- Dimension: Recovery Design
- Gap: module-resolution failure returns early after active-eval registration, which undermines exact cleanup symmetry.
- Impact: reviewed in =REPLy_jl-umg.6= as a stale-task bookkeeping risk; from a failure-handling perspective, recovery bookkeeping is incomplete.
- Evidence:
  - active eval count increments and task registers before module resolution
  - invalid module path decrements active count, but does not call =unregister_active_eval!= before return
- Remediation:
  - ensure all failure exits after partial acquisition pass through one cleanup finally block

** [EHD-3.2] [MEDIUM] =src/server.jl:close_server!= / close(MultiListenerServer)=
- Dimension: Recovery Design
- Gap: shutdown interrupts active evals and waits until deadline, but does not surface which tasks failed to stop, which were interrupted, or whether grace period was exhausted.
- Impact: shutdown is best-effort but operator visibility is weak.
- Evidence:
  - close returns =nothing=
  - no shutdown summary, no audit hook, no explicit warning on unfinished tasks after grace window
- Remediation:
  - add operator-facing summary/logging or internal metrics for interrupted vs lingering tasks

** [EHD-3.3] [MEDIUM] =src/middleware/load_file.jl=
- Dimension: Recovery Design
- Gap: path allowlist denial is safe and early, but unreadable-path errors expose raw filesystem error text.
- Impact: depending on deployment model, this may leak local path/access details to clients.
- Evidence:
  - ="Failed to read file: $(safe_showerror(ex))"=
- Remediation:
  - decide whether local path/read exceptions are safe to expose or should be normalized

** [EHD-4.1] [HIGH] =src/errors.jl= / =src/middleware/eval.jl= / =src/middleware/load_file.jl=
- Dimension: Communication
- Gap: machine-facing classification is status-flag based but incomplete and inconsistent.
- Impact: automation must parse prose error strings for some failure classes.
- Evidence:
  - status flags exist for =unknown-op=, =session-not-found=, =session-limit-reached=, =concurrency-limit-reached=, =rate-limited=, =path-not-allowed=, =timeout=
  - but no specific status flags for:
    - malformed request shape beyond generic error
    - unreadable file / filesystem failure
    - module-resolution failure
    - internal handler exception
- Remediation:
  - define stable low-cardinality machine classes or codes for all major failure families

** [EHD-4.2] [MEDIUM] =src/errors.jl:internal_error_response=
- Dimension: Communication
- Gap: internal failures are exposed using the same user-facing structure as eval/runtime errors, including stacktrace payload.
- Impact: convenient for debugging, but possibly too revealing for all deployment contexts.
- Evidence:
  - transport-level handler failures intentionally reuse eval error shape
- Remediation:
  - decide whether stacktraces are always client-visible or gated by environment/config

** [EHD-4.3] [MEDIUM] =src/middleware/eval.jl: _maybe_revise!=
- Dimension: Communication
- Gap: Revise hook failures are logged with =@warn= but not exposed to the request that triggered them.
- Impact: users may see changed runtime behavior without knowing a pre-eval hook failed; operators get warning logs only if they are watching them.
- Evidence:
  - catch block logs warning and proceeds with eval
- Remediation:
  - decide whether Revise hook failures are purely operator-facing or should optionally annotate response metadata

** [EHD-5.1] [CRITICAL] Whole reviewed runtime surface
- Dimension: Learning Loop
- Gap: no built-in post-failure learning path was found: no counters, no failure summaries, no audit integration, no explicit ownership hooks, no near-miss capture.
- Impact: repeated classes of failure can recur without the software accumulating evidence.
- Evidence:
  - =AuditLog= is standalone
  - no runtime failure path in reviewed files writes to it
  - no metric or summary API found in reviewed files
- Remediation:
  - establish one minimal observability contract for the runtime: audit, metrics, or at least structured logs with stable categories

** [VER-3.1] [HIGH] Internal consistency claim check across implementation/tests
- Layer: Logical Consistency
- Claim: the codebase appears to intend “one consistent internal-error format” and “structured error handling” broadly.
- Finding: partially true only. Internal exceptions, runtime eval failures, and load-file execution errors are consistent with that claim; timeouts, module-resolution failures, malformed JSON closes, and read failures are not uniformly represented.
- Evidence:
  - =src/errors.jl= comment says transport-level failures intentionally reuse same wire error shape as eval failures
  - however several failure classes bypass that shared abstraction
- Remediation:
  - narrow the claim in docs/comments or expand implementation consistency

* Error-Shape Inconsistency List

1. *Eval runtime / parse errors*
   - Shape: =id + status:[done,error] + err + ex + stacktrace=
   - Source: =eval_error_response=

2. *Transport handler exception*
   - Shape: same as eval runtime error
   - Source: =internal_error_response=

3. *Timeout*
   - Shape: =id + status:[done,error,timeout] + err=
   - Missing: =ex=, =stacktrace=
   - Source: custom =response_message=

4. *Interrupt terminal*
   - Shape: =id + status:[done,interrupted]=
   - No =err=
   - Source: custom =response_message=

5. *Validation failure*
   - Shape: =id + status:[done,error] + err=
   - No subcode except status array

6. *Unknown op*
   - Shape: =id + status:[done,error,unknown-op] + err=

7. *Session not found*
   - Shape: =id + status:[done,error,session-not-found] + err=

8. *Load-file allowlist denial*
   - Shape: =id + status:[done,error,path-not-allowed] + err=

9. *Load-file unreadable path*
   - Shape: =id + status:[done,error] + err=
   - No stable file-io status flag

10. *Malformed JSON / partial read*
    - Shape: none; silent connection close

11. *Oversized message*
    - Shape: =id:"" + status:[done,error] + err=
    - Then connection closes

* Missing Observability / Learning Hooks

1. No reviewed runtime use of =record_audit!=
2. No explicit malformed-input counters or audit trail
3. No explicit rate-limit audit trail
4. No explicit oversized-message audit trail
5. No shutdown summary for interrupted or lingering evals
6. No stable internal-error class/code separate from prose message
7. No structured operator-facing event for Revise hook failure
8. No reviewed metric ensuring =active_evals= and =active_eval_tasks= stay consistent after failure paths

* Needs Human Judgment

1. Should client-visible stacktraces remain enabled in all deployments, or only debug/local ones?
2. Is silent-close-on-malformed-JSON a hard protocol requirement, or should the system move toward bounded parser error feedback?
3. Is filesystem error text from =load-file= acceptable to expose to clients?
4. Should timeout include structured exception metadata or remain a protocol-level condition rather than an exception-shaped failure?
5. Is the audit subsystem intended for future integration only, or is the current lack of runtime hooks a bug-level omission?

* Explicit Test Gap List

1. No test that malformed JSON increments any metric/audit record — because no such hook exists.
2. No test that oversized-message rejection is audited or otherwise operator-visible.
3. No test that rate-limit failures are audited or logged structurally.
4. No test for exact cleanup symmetry between =active_evals= and =active_eval_tasks= after invalid module resolution.
5. No test for shutdown outcome reporting because close currently returns no summary.
6. No test that internal handler exceptions and eval errors intentionally share or diverge in full field set beyond spot checks.
7. No test asserting a stable machine code taxonomy for file I/O, module routing, or internal failures.
8. No test for Revise hook failure observability beyond warning behavior.

* Verdict Rationale

REPLy.jl is not missing failure handling; it has a decent operational skeleton. The main problem is not absence but *fragmentation*. Detection is often good, and many local recovery behaviors are sensible. What is missing is a coherent cross-cutting contract that says:
- which failure classes exist,
- how each is encoded for clients,
- what gets retried, interrupted, or disconnected,
- and what evidence is retained for operators afterward.

Because the learning/observability dimension is currently deficient and several high-value failure classes still require prose parsing or silently disappear at the runtime boundary, this review lands at *NEEDS_REWORK* rather than simple revision.
