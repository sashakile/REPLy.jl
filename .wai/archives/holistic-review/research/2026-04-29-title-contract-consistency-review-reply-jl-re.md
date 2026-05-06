---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

#+title: Contract Consistency Review: REPLy.jl (REPLy_jl-umg.3)
#+date: 2026-04-29

* Executive Summary

This pass compared the protocol specification, runtime behavior, docs, and tests for the contract-heavy parts of REPLy.jl.

Overall verdict:
- The *implemented contract* is internally consistent in several important areas: flat envelopes, echoed request IDs, newline-delimited JSON framing, one terminal =done= per request, output-before-value ordering, =session-not-found= handling, and the distinction between runtime errors and interrupt termination.
- The *written contract* is not fully aligned with the implementation. The largest issues are around session lifecycle semantics (=close=, =clone=, =ls-sessions=), malformed-input handling, and stale status documentation.
- Two notable *runtime/spec gaps* remain in concurrency-sensitive session behavior: clone and close do not synchronize with the source session's eval lock the way the spec requires.

Primary result categories:
- *Confirmed agreements:* 8
- *Material mismatches / ambiguities:* 8
- *Highest-risk findings:* 4

* Consistency Matrix

| Area | Spec / protocol docs | Runtime code | Tests | Verdict |
|-
| Request envelope shape | Flat object, =op= + =id=, kebab-case, nested values rejected | Matches =src/protocol/message.jl= | Matches =test/unit/message_test.jl= | Aligned |
| Response correlation | Every response echoes request =id= | Matches =response_message= helpers and middleware | Matches =test/helpers/conformance.jl= | Aligned |
| Stream termination | Exactly one terminal =done= per request | Matches helper + middleware pattern | Asserted by =assert_conformance= | Aligned |
| Intra-request ordering | =out/err= before =value= before =done= | Matches =src/middleware/eval.jl= | Asserted by =assert_conformance= and eval tests | Aligned |
| Invalid JSON handling | Spec says no response on invalid JSON | Runtime closes boundary with no response | E2E / unit tests agree | Aligned |
| Missing =id= handling | OpenSpec says drop/log; no response | Runtime returns error with empty echoed id | Tests agree with runtime | Mismatch |
| Close success semantics | OpenSpec says =status:["done","session-closed"]= | Runtime returns bare =done= | Tests and protocol doc match runtime | Mismatch |
| Clone without source | OpenSpec allows empty-session clone | Runtime rejects missing source | Tests and protocol doc match runtime | Mismatch |
| =ls-sessions= schema | OpenSpec says per-session metadata with =id= | Runtime emits =session= UUID plus richer fields | Tests and how-to docs match runtime | Mismatch |
| Session lifecycle states | OpenSpec names CREATED/ACTIVE/EVAL_RUNNING/DESTROYED | Runtime uses SessionIdle/SessionRunning/SessionClosed | Tests and docs match runtime | Mismatch |
| Interrupt termination | Non-error terminal =done + interrupted= | Matches eval/interrupt middleware | Tests and status docs agree | Aligned |
| Limit status flags | =session-limit-reached=, =concurrency-limit-reached= etc. | Implemented in middleware | Tests and docs agree where documented | Mostly aligned |

* Confirmed Agreements

** 1. Flat request envelopes are enforced consistently
- *Spec source:* =openspec/specs/protocol/spec.md=, "Requirement: Flat JSON Envelope" and "Requirement: Kebab-Case Field Names"
- *Code:* =src/protocol/message.jl=
  - rejects non-string =id=
  - rejects empty =id=
  - rejects missing/non-string =op=
  - rejects non-kebab-case keys
  - rejects nested values
- *Tests:* =test/unit/message_test.jl=
- *Docs:* =docs/src/reference-protocol.md=, "Request Envelope"

Verdict: implementation, tests, and docs agree on flat envelopes and kebab-case keys.

** 2. Response correlation by echoed =id= is consistent
- *Spec:* =openspec/specs/protocol/spec.md=, "Requirement: Response Correlation"
- *Code:* =src/protocol/message.jl= =response_message(...)= seeds every message with ="id" => request_id=
- *Tests:* =test/helpers/conformance.jl= requires all messages to carry the same request id

Verdict: aligned.

** 3. One terminal =done= per request is consistently enforced
- *Spec:* =openspec/specs/protocol/spec.md=, "Requirement: Stream Termination"
- *Code pattern:* =done_response(...)= and middleware terminal paths
- *Tests:* =test/helpers/conformance.jl= asserts exactly one =done= and that it is the final message

Verdict: aligned.

** 4. Ordering guarantees are implemented and tested
- *Spec:* =openspec/specs/protocol/spec.md=, "Requirement: Intra-Request Ordering"
- *Code:* =src/middleware/eval.jl= appends buffered =out= / =err= before =value= and then =done=
- *Tests:* =test/helpers/conformance.jl= and eval tests

Verdict: aligned.

** 5. Malformed JSON closes the boundary without a protocol response
- *Spec:* =openspec/specs/core-operations/spec.md=, malformed input scenario for invalid JSON
- *Code:* =src/protocol/message.jl= returns =nothing= when JSON parsing fails
- *Tests:* =test/unit/message_test.jl= malformed JSON treated as closed boundary; =test/e2e/eval_test.jl= malformed JSON closes the connection without a protocol response
- *Docs:* =docs/src/reference-protocol.md=, "Malformed Input"

Verdict: aligned.

** 6. Interrupts are non-error terminal states
- *Spec:* =openspec/specs/error-handling/spec.md=, interrupted has =done + interrupted= and no =error=
- *Code:* =src/middleware/eval.jl= emits ={"status":["done","interrupted"]}= on =InterruptException=
- *Tests:* =test/unit/interrupt_middleware_test.jl= and =test/unit/eval_middleware_test.jl=
- *Docs:* =docs/src/status.md= explicitly describes interrupt semantics this way

Verdict: aligned.

** 7. Session-not-found behavior is consistent in named-session routing
- *Code:* =src/middleware/session.jl= validates and resolves any =session= key before downstream handling
- *Tests:* =test/integration/session_lifecycle_test.jl= and =test/integration/session_ops_test.jl=
- *Docs:* =docs/src/reference-protocol.md= status flags table includes =session-not-found=

Verdict: aligned.

** 8. Ephemeral sessions are excluded from =ls-sessions=
- *Spec:* =openspec/specs/session-management/spec.md=, ephemeral evals do not appear in =ls-sessions=
- *Code:* =src/session/manager.jl= keeps ephemeral and named registries separate
- *Tests:* =test/unit/session_ops_middleware_test.jl= and =test/integration/session_ops_test.jl=
- *Docs:* =docs/src/howto-sessions.md=

Verdict: aligned.

* Prioritized Mismatch List

** [CC-1] [HIGH] [Ambiguity] Missing =id= behavior differs between OpenSpec and runtime/tests
- *Area:* request envelopes / malformed input
- *Spec claim:* =openspec/specs/core-operations/spec.md= says missing =id= should be logged and dropped with no response.
- *Runtime:* =src/protocol/message.jl= =validate_request(...)= returns =error_response("", "id must not be empty")= when =id= is absent.
- *Tests:* =test/unit/message_test.jl= asserts the empty-id error response shape.
- *Docs:* =docs/src/reference-protocol.md= says =id= is required, but does not document missing-=id= behavior.

Why this matters:
Clients either receive a recoverable protocol error or see silent drop behavior. That is observable wire behavior and needs one source of truth.

Recommendation:
Decide whether missing =id= is a hard-drop boundary or a recoverable protocol error. Then align spec, tests, and docs to one rule.

** [CC-2] [LOW] [Ambiguity] Missing =op= error wording differs between OpenSpec and runtime/tests
- *Area:* request envelopes
- *Spec claim:* =openspec/specs/core-operations/spec.md= scenario says error text is ="Missing required field: op"=.
- *Runtime:* =src/protocol/message.jl= returns ="op is required"=.
- *Tests:* =test/unit/message_test.jl= asserts ="op is required"=.

Why this matters:
Mostly low severity, but contract-heavy client tests sometimes snapshot exact error strings.

Recommendation:
Standardize the normative error text or explicitly declare error text non-normative.

** [CC-3] [HIGH] [Ambiguity] =close= success status disagrees across spec, code, and docs
- *Area:* response streams / status flags / session semantics
- *Spec claim:* =openspec/specs/core-operations/spec.md= says successful =close= returns ={"status":["done","session-closed"]}=.
- *Runtime:* =src/middleware/session_ops.jl= returns bare =done_response(request_id)= on successful close.
- *Tests:* =test/unit/session_ops_middleware_test.jl= and =test/integration/session_ops_test.jl= verify conformance but do not require =session-closed=.
- *Docs conflict internally:*
  - =docs/src/reference-protocol.md= says =close= returns bare =done=
  - =docs/src/status.md= says =close= returns =session-closed= or =session-not-found=

Why this matters:
This is a direct client-visible status-flag inconsistency and the docs disagree with themselves.

Recommendation:
Pick one success contract for =close= and align spec, runtime, tests, and both docs pages.

** [CC-4] [HIGH] [Ambiguity] =clone= empty-session semantics differ between OpenSpec and current implementation
- *Area:* session semantics
- *Spec claim:* =openspec/specs/core-operations/spec.md= says =clone= without =session= creates an empty session and returns =new-session=.
- *Runtime:* =src/middleware/session_ops.jl= validates a source identifier; missing source becomes an error.
- *Tests:* =test/unit/session_ops_middleware_test.jl= explicitly expects an error when neither =session= nor =source= is present.
- *Docs:* =docs/src/reference-protocol.md= lists =clone= as requiring =name= and an optional source session; no empty-session clone path is documented.

Why this matters:
This changes how clients create persistent sessions. The current codebase appears to have split "create empty session" into =new-session= and "copy existing session" into =clone=, but OpenSpec still models a different API.

Recommendation:
Clarify whether =new-session= supersedes source-less =clone=. If yes, update OpenSpec. If no, runtime/tests/docs need changes.

** [CC-5] [MEDIUM] [Ambiguity] =ls-sessions= response schema differs between OpenSpec and implementation/docs/tests
- *Area:* session semantics / protocol schema
- *Spec claim:* =openspec/specs/core-operations/spec.md= says =ls-sessions= returns per-session metadata including =id=, =type=, =created=, =last-activity=.
- *Runtime:* =src/middleware/session_ops.jl= emits per-session dicts with =session= (UUID), =name=, =created=, =created-at=, =last-activity=, =type=, =module=, =eval-count=, =pid=.
- *Tests:* =test/unit/session_ops_middleware_test.jl= asserts =session= UUID field and the richer metadata.
- *Docs:* =docs/src/howto-sessions.md= shows the richer runtime shape using =session=, not =id=.

Why this matters:
This is a schema-level mismatch for clients consuming =ls-sessions=.

Recommendation:
Choose whether =session= is the canonical wire key or whether =id= should be added/restored. Document compatibility policy.

** [CC-6] [MEDIUM] [Ambiguity] Session lifecycle model in OpenSpec no longer matches code/docs/tests
- *Area:* session semantics / invariants
- *Spec claim:* =openspec/specs/session-management/spec.md= names lifecycle states CREATED / ACTIVE / EVAL_RUNNING / DESTROYED.
- *Runtime:* =src/session/module_session.jl= defines only =SessionIdle=, =SessionRunning=, =SessionClosed=.
- *Docs:* =docs/src/howto-sessions.md= documents =SessionIdle= / =SessionRunning= / =SessionClosed=.
- *Tests:* session-registry and lifecycle tests exercise the three-state runtime model.

Why this matters:
State-machine names and transitions influence interrupt/close/timeout reasoning and formal-review work downstream.

Recommendation:
Either update OpenSpec to the 3-state model or restore/document the 4-state lifecycle if it is still intended.

** [CC-7] [HIGH] [Code bug] Clone does not wait for in-flight eval completion before copying bindings
- *Area:* session semantics / concurrency
- *Spec claim:* =openspec/specs/core-operations/spec.md= says clone waits for the eval mutex before deep-copying bindings when the source session has an active eval.
- *Runtime:* =src/session/manager.jl= =clone_named_session!(...)= copies module bindings without acquiring =session.eval_lock= from the source session.
- *Supporting structure:* =src/session/module_session.jl= documents =eval_lock= as the named-session serialization primitive.
- *Test coverage:* no test was found asserting clone-vs-running-eval synchronization.

Why this matters:
A concurrent clone can observe a transient or partially updated module state and violate the session-copy contract.

Recommendation:
Treat as a runtime bug unless the concurrency contract has been intentionally weakened. Add a targeted test either way.

** [CC-8] [HIGH] [Code bug] Close does not synchronize with queued/running evals the way the session spec requires
- *Area:* session semantics / status transitions
- *Spec claim:* =openspec/specs/session-management/spec.md= says close acquires the eval mutex before destroying; queued evals should observe removal and return =session-not-found=.
- *Runtime:* =src/middleware/session_ops.jl= closes via direct lookup + =destroy_named_session!= and =src/session/manager.jl= removes the session without acquiring =eval_lock=.
- *Tests:* current close tests cover idle close success and missing-session errors, but no targeted close-vs-queued-eval race contract was found.

Why this matters:
This is a concurrency-visible gap in the session lifecycle contract and affects interrupt/close determinism.

Recommendation:
Treat as a runtime bug unless OpenSpec is being revised downward. Add a race-focused test.

* Documentation-Specific Findings

** [DOC-1] [HIGH] [Doc bug] =docs/src/status.md= materially understates the implemented contract surface
- The page still claims several implemented features are absent:
  - session lifecycle ops
  - named sessions
  - unix sockets and multi-listener transport
  - resource limits and audit logging
  - MCP adapter
  - multiple middleware-backed operations beyond =eval=
- This conflicts with current runtime files and tests, including:
  - =src/middleware/session_ops.jl=
  - =src/server.jl=
  - =src/mcp_adapter.jl=
  - =src/security/audit.jl=
  - =test/e2e/unix_socket_test.jl=
  - =test/e2e/multi_listener_test.jl=
  - =test/unit/mcp_adapter_test.jl=

Why this matters:
The page is likely to mislead both humans and future agents about what the system actually does.

** [DOC-2] [MEDIUM] [Doc bug] =docs/src/reference-protocol.md= calls itself the complete reference but omits implemented operations
Missing implemented ops from the page include:
- =describe=
- =load-file=
- =interrupt=
- =complete=
- =lookup=
- =stdin=

This is a completeness/trust issue rather than a broken-link issue.

* Ambiguities Requiring Design Clarification

1. Is =new-session= now the sole empty-session creation op, with =clone= reserved for copy-from-parent only?
2. Should successful =close= include =session-closed= as a status flag, or is bare =done= the canonical contract?
3. Should missing =id= be dropped silently or answered with an error using empty echoed id?
4. Is the 3-state runtime session model the intended long-term protocol model, or is OpenSpec's 4-state machine still normative?
5. Is =ls-sessions= canonical UUID key name =session= or =id=?

* Confidence Rationale

Confidence is *moderate to high* for the mismatch inventory because the findings are grounded in direct file comparisons across OpenSpec, runtime code, tests, and user-facing docs. The two runtime concurrency findings (=clone= and =close= synchronization) are especially important because the spec states explicit behavior and the implementation path does not currently take the documented lock. The main uncertainty is normative intent: in several places the code/tests/docs agree with each other against an older or different OpenSpec contract, which is why those findings are classified as *ambiguity* rather than automatically as code defects.

* Recommended Next Steps

1. Resolve the five protocol/session ambiguities before further contract-heavy implementation work.
2. File follow-up tickets separately for:
   - docs refresh (=status.md=, =reference-protocol.md=)
   - close success flag normalization
   - clone-without-source contract normalization
   - missing-id contract normalization
   - clone/close synchronization race tests
3. Use the resolved contract as the baseline for tickets =REPLy_jl-umg.6=, =.7=, =.10=, and =.11=, which all depend on crisp session and error semantics.
