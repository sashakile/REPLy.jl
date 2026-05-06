---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

#+title: Test Suite Duplication, Friction, and Coverage Review: REPLy.jl (REPLy_jl-umg.11)
#+date: 2026-04-29

* Executive Summary

This pass reviewed the =test/= tree through three lenses:
- =test-abstraction-miner=
- =test-friction=
- =edge-case-discovery=

Overall verdict:
- The suite is *broad and layered*: unit, integration, and e2e coverage are all real and are already catching contract drift and many concurrency-adjacent behaviors.
- The main weakness is *volume without enough abstraction*. The suite repeats the same harness construction and assertion shapes across many files, especially in middleware and session tests.
- The dominant test friction signal is not mocking complexity; it is *manual orchestration complexity*: repeated handler/stack/context/server/socket setup, repeated polling loops for async state, and large monolithic files that mirror production branching.
- Missing coverage is now concentrated in *race-heavy and contract-edge* behaviors already surfaced by earlier review passes, rather than basic happy paths.

Primary result categories:
- Strong layer coverage areas: 7
- Lazy-test / duplication clusters: 9
- Test-friction findings: 6
- Coverage-gap groups: 8

Test infrastructure summary:
- Framework: Julia =Test=
- PBT library detected: *none*
- Static quality layers present: =Aqua= and =JET= in =test/quality_test.jl=

* Suite Structure Assessment

The suite is organized coherently by layer:
- *Unit*: protocol, middleware, session internals, resource limits, descriptors, adapter helpers, audit log, revise hook
- *Integration*: pipeline, lifecycle, session ops, named-session persistence
- *E2E*: TCP, Unix socket, multi-listener, named sessions, revise hook

Helpers provide some shared abstraction already:
- =test/helpers/conformance.jl= — stream-shape assertions
- =test/helpers/server.jl= — server lifecycle wrappers
- =test/helpers/tcp_client.jl= — send/collect helpers

However, many domain-specific setup patterns are still reimplemented locally in each file.

* Summary Table

| Area | Finding Type | Signal | Priority |
|-
| unit middleware tests | Lazy Test cluster | repeated =make_ctx() + stack + dispatch + shape assertions= | HIGH |
| session tests | Lazy Test cluster | many create/lookup/destroy/state-transition variations with near-identical setup | HIGH |
| session ops tests | Lazy Test cluster | very large matrix of op variants encoded as hand-written tests | HIGH |
| async interrupt/stdin/eval tests | Test friction | repeated polling loops and channels imply orchestration burden | HIGH |
| e2e transport tests | Lazy Test cluster | repeated connect/send/collect/conformance/value pattern | MEDIUM |
| integration session tests | Duplication + friction | named-session persistence/isolation cases repeated across integration and e2e | MEDIUM |
| quality/static checks | Strength | Aqua + JET provide non-example-based coverage | LOW |

* Confirmed Strengths

** Strength 1 — The suite has real layer separation
- Evidence: =test/runtests.jl=
- Why it matters:
  - unit tests catch local contract errors
  - integration tests exercise handler composition
  - e2e tests pressure transport and server boundaries

** Strength 2 — Protocol conformance is factored once and reused
- Evidence: =test/helpers/conformance.jl=
- Why it matters:
  - many tests avoid re-asserting id echo / done placement / ordering manually
  - this reduces one important class of duplication already

** Strength 3 — There is meaningful coverage of server transports and topologies
- Evidence:
  - =test/e2e/eval_test.jl=
  - =test/e2e/unix_socket_test.jl=
  - =test/e2e/multi_listener_test.jl=
- Why it matters:
  - transport regressions are not left entirely to unit tests

** Strength 4 — Session semantics are covered from multiple angles
- Evidence:
  - =test/unit/session_registry_test.jl=
  - =test/unit/session_ops_middleware_test.jl=
  - =test/integration/session_lifecycle_test.jl=
  - =test/e2e/named_session_eval_test.jl=

** Strength 5 — Failure-path tests are present, not just success-path tests
- Evidence:
  - =test/unit/message_test.jl=
  - =test/unit/error_test.jl=
  - =test/unit/resource_enforcement_test.jl=
  - =test/unit/disconnect_cleanup_test.jl=

** Strength 6 — Optional capability tests exist for non-default middleware
- Evidence:
  - =test/unit/complete_middleware_test.jl=
  - =test/unit/lookup_middleware_test.jl=
  - =test/unit/load_file_middleware_test.jl=
  - =test/unit/describe_middleware_test.jl=

** Strength 7 — Static quality tests complement example-based tests
- Evidence: =test/quality_test.jl=
- Why it matters:
  - Aqua and JET reduce reliance on only hand-authored examples

* Lazy-Test / Duplication Inventory

No property-based testing library was detected in =test/Project.toml=. Property escalations below are therefore prose-only proposals.

** Cluster 1 — Middleware happy/error skeleton repeated across small capability files
- Files:
  - =test/unit/complete_middleware_test.jl=
  - =test/unit/lookup_middleware_test.jl=
  - =test/unit/load_file_middleware_test.jl=
  - parts of =test/unit/describe_middleware_test.jl=
- Invariant:
  - create =RequestContext=
  - build local =AbstractMiddleware[TargetMiddleware(), UnknownOpMiddleware()]= stack
  - dispatch one request
  - assert two-message success shape or one-message error shape
- Variant:
  - operation name, required field names, and result payload keys
- Count:
  - 20+ tests across these files
- Why it is a Lazy Test cluster:
  - same control flow, same assertion shape, only literals/field names vary
- Parameterization proposal:
  - a shared helper such as “assert_missing_required_field_errors(mw, op, field_name, base_request)” and “assert_non_target_ops_forward(mw, foreign_op)”
- Property proposal (prose only):
  - For middleware with required scalar fields, property: removing any required field yields exactly one terminal error response with matching echoed id and no partial payload messages.
- Priority: HIGH

** Cluster 2 — Repeated =make_ctx()= / =RequestContext(... nothing)= helpers
- Files:
  - =complete_middleware_test.jl=
  - =lookup_middleware_test.jl=
  - =store_history_test.jl=
  - =eval_option_compliance_test.jl=
  - others
- Signal:
  - many files define tiny local helper functions that differ only cosmetically
- Why it matters:
  - low-level duplication, but also a sign the production harness is awkward enough that every file reinvents it
- Proposal:
  - centralize context helpers in =test/helpers/= with variants for bare, named-session, and server-state-backed contexts
- Priority: MEDIUM

** Cluster 3 — Repeated named-session creation / handler setup in integration tests
- Files:
  - =test/integration/named_session_persistence_test.jl=
  - =test/integration/session_lifecycle_test.jl=
  - =test/integration/session_ops_test.jl=
- Invariant:
  - create manager
  - create named sessions
  - build handler
  - perform one or more eval/session-op calls
  - assert persistence/isolation/close outcomes
- Variant:
  - session names, code snippets, and terminal assertions
- Proposal:
  - scenario-table helpers for common “create handler + run request + extract value/status” flows
- Priority: MEDIUM

** Cluster 4 — E2E request/response handshake repeated across TCP/Unix/multi-listener tests
- Files:
  - =test/e2e/eval_test.jl=
  - =test/e2e/unix_socket_test.jl=
  - =test/e2e/named_session_eval_test.jl=
  - =test/e2e/multi_listener_test.jl=
  - =test/e2e/revise_hook_test.jl=
- Invariant:
  - start server
  - connect socket(s)
  - =send_request=
  - =collect_until_done=
  - =assert_conformance=
  - assert one value/status fact
- Variant:
  - transport, request body, value/status expectation
- Proposal:
  - transport-agnostic scenario driver helpers, especially for single-request success/error cases
- Property proposal (prose only):
  - for any transport/listener combination, same request contract should produce equivalent terminal stream classification modulo transport-specific setup.
- Priority: MEDIUM

** Cluster 5 — Session registry state tests could be table-driven in parts
- File: =test/unit/session_registry_test.jl=
- Signal:
  - many tests check simple single-operation facts over fresh managers/sessions
- Caveat:
  - not all should collapse; many cover distinct semantics
- Safe collapse candidates:
  - invalid transition cases
  - lookup-by-name/UUID equivalence cases
  - destroy-by-name/UUID cleanup cases
- Priority: MEDIUM

** Cluster 6 — Session op schema variants are hand-expanded
- File: =test/unit/session_ops_middleware_test.jl=
- Signal:
  - canonical/deprecated names, UUID/name aliases, required/optional field combinations, and shape checks are encoded as many near-isomorphic tests
- Count:
  - largest cluster in the suite
- Why this matters:
  - file has 1000+ lines and mirrors production branching almost one-for-one
- Proposal:
  - table-drive schema variants by op, field combination, and expected flag/result keys
- Property proposal (prose only):
  - op aliasing property: canonical and deprecated forms preserving equivalent semantic inputs should agree on terminal classification and target object mutation, modulo documented response-shape differences.
- Priority: HIGH

** Cluster 7 — Interrupt tests repeat a common async orchestration recipe
- File: =test/unit/interrupt_middleware_test.jl=
- Invariant:
  - create named session
  - launch blocking eval asynchronously
  - poll until =SessionRunning=
  - send interrupt
  - observe reply and eval completion
- Variant:
  - targeted vs untargeted interrupt-id, idle vs running, match vs mismatch
- Why this is only partially collapsible:
  - semantics differ, but orchestration does not
- Proposal:
  - helper to start blocking eval and wait until running
- Priority: HIGH

** Cluster 8 — Revise hook tests are duplicated across unit and e2e layers
- Files:
  - =test/unit/revise_hook_test.jl=
  - =test/e2e/revise_hook_test.jl=
- Signal:
  - same three scenarios: hook enabled, hook skipped for ephemeral, hook disabled by config
- Caveat:
  - duplication is partly justified because unit and e2e validate different layers
- Advisory:
  - keep both layers, but factor mock-Revise setup and shared scenario naming if possible
- Priority: LOW-MEDIUM

** Cluster 9 — Resource limit transport checks are partially hand-mirrored
- Files:
  - =test/unit/message_test.jl=
  - =test/unit/resource_enforcement_test.jl=
  - =test/e2e/multi_listener_test.jl=
- Signal:
  - oversize, rate-limit, session-limit, concurrent-eval-limit patterns use similar “submit request -> terminal status contains X” logic
- Proposal:
  - shared helpers for terminal-flag assertions on limit failures
- Priority: MEDIUM

* Test Friction Report

| Location | Friction Signal | Likely Smell | Missing Abstraction | Priority |
|-
| =test/unit/session_ops_middleware_test.jl= | huge single file, many near-isomorphic cases | production branching mirrored in tests | scenario table / op contract abstraction | HIGH |
| =test/unit/session_registry_test.jl= | large state-matrix file with repeated setup | mutable state machine tested one transition at a time | lifecycle test DSL / helper seam | HIGH |
| =test/unit/interrupt_middleware_test.jl=, =stdin_middleware_test.jl=, parts of =eval_middleware_test.jl= | repeated polling loops and async channels | concurrency orchestration burden exposed to tests | async harness helper | HIGH |
| many small middleware tests | local =make_ctx= / local stack assembly repeated | low-level harness awkwardness | shared test context builders | MEDIUM |
| e2e transport tests | socket lifecycle boilerplate | transport driver setup leaking into every test | transport scenario helpers | MEDIUM |
| revise hook tests | mock binding / cleanup ceremony | global-state seam in production design | dedicated Revise seam/helper | MEDIUM |

** Friction 1 — Test harness construction is too manual for middleware-level tests
- Evidence:
  - repeated local =make_ctx()=
  - repeated =AbstractMiddleware[Target(), UnknownOpMiddleware()]=
  - repeated direct =dispatch_middleware(...)= calls
- Smell:
  - missing seam for “single middleware under test” execution
- Production design pressure:
  - middleware is testable, but only through fairly raw plumbing
- Suggested refactoring direction:
  - not a runtime change first; begin with test-only helpers that express intent (“run complete”, “run lookup”, “run load-file”)

** Friction 2 — Async state tests require hand-rolled polling everywhere
- Evidence:
  - repeated =timeout = time() + 5.0; while ... yield(); ...= loops in interrupt/stdin/eval/session lifecycle tests
- Smell:
  - concurrency state has no single test seam for “wait until running / wait until complete”
- Production design pressure:
  - externally observable async transitions exist, but the test API exposes them only indirectly through polling mutable state
- Suggested refactoring direction:
  - helper seam around starting blocking evals and waiting for lifecycle milestones

** Friction 3 — Session ops tests mirror production conditional complexity
- Evidence:
  - =test/unit/session_ops_middleware_test.jl= is 1000+ lines with many schema variants
- Smell:
  - contract complexity and backward-compat layers in production surface directly as test sprawl
- Production design pressure:
  - canonical/deprecated op names and alias/UUID duality increase scenario count
- Suggested refactoring direction:
  - scenario matrix tables grouped by semantic family: listing, close, clone, validation, alias compatibility

** Friction 4 — Revise hook tests reveal global-state coupling to =Main=
- Evidence:
  - unit and e2e tests inject/remove =Main.Revise=
- Smell:
  - missing explicit seam around pre-eval hook dependency
- Production design pressure:
  - hook depends on global bindings and world-age behavior
- Suggested refactoring direction:
  - eventually isolate hook behind a callable dependency or adapter seam; for now, centralize test helper usage

** Friction 5 — Some integration/e2e coverage duplicates unit semantics instead of only layer-specific risk
- Evidence:
  - named-session persistence/isolation patterns recur across unit, integration, and e2e
- Ambiguity:
  - some duplication is good because each layer exercises a different boundary
- Judgment:
  - retain layer overlap where the *boundary* changes; collapse only exact scenario mechanics

** Friction 6 — Lack of property-based tooling keeps the suite example-heavy
- Evidence: =test/Project.toml= has no PBT library
- Smell:
  - many input-partition tests are written as hand-picked enumerations
- Suggested refactoring direction:
  - add PBT only where strong algebraic or partition properties exist; do not replace targeted regression examples blindly

* Coverage Gap Matrix by Subsystem

| Subsystem | Covered Well | Missing / Thin Coverage |
|-
| protocol validation | ids, op presence/type, kebab-case, flat envelope, oversize messages | fuzzier malformed-input sequences, repeated malformed-message policy |
| session registry | create/lookup/destroy/clone basics, UUID/alias lookup, sweep, state transitions | explicit UUID replacement alias drift, replace-while-running races |
| session ops middleware | close/clone/list/new-session schemas and compat variants | clone/close race semantics under active eval, partial clone rollback |
| eval middleware | stdout/stderr ordering, empty code, errors, timeout, eval-id, locks | cleanup symmetry after all early exits, module-resolution + server-state invariants |
| interrupt/stdin | running/idle/mismatch cases, delivered/buffered paths | race of interrupt/stdin against concurrent close/replacement |
| load-file | allowlist, unreadable file, syntax error, stdout capture | concurrent interactions with session lifecycle, large-file / large-output boundaries |
| server / shutdown | disconnect resilience, graceful close basics, multi-listener basics | operator-visible shutdown outcome reporting, lingering task summary, stale active-task bookkeeping |
| observability / audit | audit log unit behavior | runtime integration entirely absent in tested surface |

* Missing Edge-Case Coverage (Grouped)

** Group 1 — Session race semantics (highest priority)
Missing explicit tests for:
1. close vs running eval
2. close vs queued same-session eval
3. clone vs running eval snapshot consistency
4. same-name replacement while eval is running
5. stdin vs concurrent close/replacement
6. interrupt vs close precedence when both target the same running eval

These gaps align directly with `.6` findings.

** Group 2 — Failure bookkeeping invariants
Missing explicit tests for:
1. =active_evals= and =active_eval_tasks= consistency after invalid-module early failure
2. post-failure bookkeeping symmetry for every eval early-return branch
3. shutdown behavior when some active tasks ignore or outlive grace period

These align directly with `.7` findings.

** Group 3 — Audit / observability integration
Missing tests for:
1. runtime audit entry on oversized message
2. runtime audit entry on rate-limited request
3. runtime audit entry on malformed JSON close
4. runtime audit entry on internal handler exception
5. runtime audit entry on path-not-allowed denial

Current reason: those integrations do not appear to exist.

** Group 4 — Contract-authority edge cases
Missing explicit tests for whichever contract is intended on:
1. missing =id= semantics if OpenSpec is made authoritative
2. =close= success flag normalization
3. =clone= without source normalization
4. =ls-sessions= canonical UUID key name if contract changes

These depend on resolution of `.3` findings.

** Group 5 — Property-like data spaces currently covered only by hand-picked examples
Candidates for prose-level property testing later:
1. request validation partitions over key shape / nested values / id bounds
2. session-name validation accepted/rejected partitions
3. clone independence for mutable containers beyond one or two examples
4. output truncation UTF-8 safety over broader Unicode inputs
5. middleware descriptor validation over generated stacks

* Property Escalation Proposals (Prose Only)

No PBT library detected. If adopted later, these are the best candidates:

1. *Validation partition property*
   - For any request map with a non-kebab-case key or nested value, =validate_request= returns one terminal error response.

2. *Session-name partition property*
   - Names matching the allowed character/length grammar are accepted; all others fail before lookup.

3. *Clone non-interference property*
   - After cloning a session, mutating clone-only bindings must not change the source session’s corresponding values for immutable and deepcopy-supported mutable bindings.

4. *Conformance property*
   - Any successful request stream contains exactly one terminal =done=, with all non-terminal payload messages preceding it.

5. *Descriptor stack law*
   - For any middleware stack with duplicate providers or unsatisfied prereqs, =validate_stack= reports at least one matching error; for stacks generated from a valid topological order, it reports none.

* Top Opportunities for Test Abstraction

1. Introduce shared *context/stack builders* in =test/helpers/=
2. Introduce shared *async wait helpers* for “wait until running” / “wait until reader done”
3. Introduce *request scenario drivers* for unit middleware tests
4. Introduce *transport scenario drivers* for e2e request/response cases
5. Table-drive =session_ops_middleware_test.jl= by semantic family rather than one handwritten block per variant

* Verdict

Verdict: *NEEDS REFINEMENT, NOT REPLACEMENT*

Rationale:
- The suite is valuable and already catches important regressions.
- The main issue is maintainability and signal density, not lack of intent.
- The largest wins now are:
  1. abstracting repeated harness code,
  2. shrinking monolithic session-op/state files into table-shaped scenario families,
  3. adding a focused set of race and bookkeeping tests for the exact weak spots surfaced by `.6` and `.7`.

If the next step is backlog shaping, the best follow-up tickets are:
- test helper extraction for async/session/transport harnesses
- session-op test matrix consolidation
- race-focused coverage tickets for close/clone/stdin/interrupt interactions
- audit/observability integration tests once runtime hooks exist
