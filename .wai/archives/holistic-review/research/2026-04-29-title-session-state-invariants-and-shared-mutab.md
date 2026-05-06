---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

#+title: Session/State Invariants and Shared Mutability Review: REPLy.jl (REPLy_jl-umg.6)
#+date: 2026-04-29

* Executive Summary

This pass reviewed the session/state subsystem through three lenses required by the ticket:
- invalid-states-diagnostician
- mutability-diagnostician
- edge-case-discovery

Overall verdict:
- The *intended* model is coherent: ephemeral and named sessions are separated, named sessions have a small explicit lifecycle, per-session evals are serialized with =eval_lock=, and most public middleware paths preserve the main invariants.
- The *enforcement* of those invariants is partial. Several critical properties live in comments, lock-order conventions, or caller discipline rather than being structurally enforced by types or APIs.
- The highest-risk findings cluster around *detached-but-still-running session objects*, *clone/close races with in-flight evals*, *registry consistency under replacement paths*, and *server-wide counter/task bookkeeping drift*.

Primary result categories:
- Confirmed invariants: 9
- Representable invalid states: 8
- Concurrency / mutation hazards: 8
- Explicit edge-case test gaps: 12

* Files Reviewed

Core implementation:
- =src/session/module_session.jl=
- =src/session/manager.jl=
- =src/config/server_state.jl=
- =src/middleware/session.jl=
- =src/middleware/session_ops.jl=
- =src/middleware/stdin.jl=
- =src/middleware/eval.jl=
- =src/config/resource_limits.jl=

Test surface reviewed:
- =test/unit/session_test.jl=
- =test/unit/session_registry_test.jl=
- =test/unit/session_ops_middleware_test.jl=
- =test/unit/stdin_middleware_test.jl=
- =test/unit/store_history_test.jl=
- =test/unit/eval_middleware_test.jl=
- =test/integration/session_lifecycle_test.jl=
- =test/integration/session_ops_test.jl=
- =test/integration/named_session_persistence_test.jl=
- =test/e2e/named_session_eval_test.jl=

* Invariant Catalog

** INV-1 Registry separation is the main session-shape invariant
- Source: =src/session/manager.jl=
- Intended rule:
  - ephemeral sessions live only in =ephemeral_sessions=
  - named sessions live only in =named_sessions=
  - only named sessions appear in =list_named_sessions=
- Evidence:
  - =create_ephemeral_session!=, =destroy_session!=, =session_count=
  - =create_named_session!=, =list_named_sessions=
  - tests in =test/unit/session_registry_test.jl=
- Status: *holds on normal paths*

** INV-2 Alias/UUID dual identity is the persistent-session lookup contract
- Source: =lookup_named_session= and =_resolve_to_uuid_and_session= in =src/session/manager.jl=
- Intended rule:
  - each live named session has one canonical UUID
  - optional human alias points to that UUID via =name_to_uuid=
  - callers may address a session by UUID or alias
- Status: *mostly holds on normal create/lookup/destroy paths*, but see IS-3 and IS-4.

** INV-3 Named session lifecycle is a 3-state runtime machine
- Source: =@enum SessionState= in =src/session/module_session.jl=
- States:
  - =SessionIdle=
  - =SessionRunning=
  - =SessionClosed=
- Valid public transitions:
  - Idle -> Running
  - Running -> Idle
  - Closed is terminal and reached only through destruction helpers
- Status: *enforced by helper functions, but raw field mutation remains possible*

** INV-4 State/task/activity fields are intended to move atomically together
- Source: =begin_eval!=, =end_eval!=, =try_begin_eval!=
- Intended rule:
  - entering =SessionRunning= sets =eval_task=, bumps =eval_id=, updates =last_active_at=
  - leaving running clears =eval_task=, returns to idle, updates =last_active_at=, increments =eval_count=
- Status: *holds when callers use helpers correctly*

** INV-5 Per-session FIFO depends on external lock discipline
- Source: =src/middleware/eval.jl= and =src/session/module_session.jl=
- Intended rule:
  - named-session evals must take =session.eval_lock=
  - only then may they call =try_begin_eval!=
- Status: *holds in eval middleware and load-file middleware*, but is not structurally enforced for other callers.

** INV-6 Lock ordering convention is manager.lock -> session.lock
- Source: =destroy_named_session!= and =sweep_idle_sessions!= in =src/session/manager.jl=
- Intended rule:
  - code acquiring both locks must take =manager.lock= first, then =session.lock=
  - =eval_lock= is separate and not governed by =session.lock=
- Status: *documented and mostly followed*, but not encoded in the type/API surface.

** INV-7 Successful named-session evals update history and =ans=
- Source: =_update_history!= in =src/middleware/eval.jl=
- Intended rule:
  - only successful evals with =store-history != false= update =ans= and =history=
  - history is bounded by =clamp_history!=
- Status: *holds for the current middleware path*
- Important caveat: the bound currently follows =MAX_SESSION_HISTORY_SIZE=, not =ResourceLimits.max_session_history=.

** INV-8 Server-wide eval accounting is split across two structures
- Source: =src/config/server_state.jl= and =src/middleware/eval.jl=
- Intended rule:
  - =active_evals[]= current in-flight count
  - =active_eval_tasks= contains the current eval tasks
  - registration and unregistration should track the same eval population
- Status: *intended invariant is clear*, but there is at least one bookkeeping escape hatch; see IS-6 / HAZ-5.

** INV-9 stdin delivery semantics depend on current session state snapshot
- Source: =stdin_responses= in =src/middleware/stdin.jl=
- Intended rule:
  - running session -> response says =delivered=
  - idle session -> response says =buffered=
  - closed or missing session -> error
- Status: *works under stable state*, but classification is snapshot-based and races with close/replacement; see HAZ-4.

* Representable Invalid States

| ID | Location | Signal | Invalid State | Severity |
|-
| IS-1 | =src/session/module_session.jl= | Public mutable record | =NamedSession= can exist with mismatched combinations such as Running + =eval_task = nothing= or Idle + non-nothing =eval_task= by direct field mutation | HIGH |
| IS-2 | =src/session/module_session.jl= / =src/session/manager.jl= | Caller-disciplined typestate | =try_begin_eval!= is safe only if caller already holds =eval_lock=; API permits calls without that precondition | HIGH |
| IS-3 | =src/session/manager.jl:create_named_session!= | Implicit coupling gap | alias replacement can produce a *closed but externally referenced* old session object while a new session now owns the alias | HIGH |
| IS-4 | =src/session/manager.jl:create_named_session!= | Registry drift | supplying an existing explicit UUID with a different name can leave stale alias mappings pointing at the replacement session | MEDIUM |
| IS-5 | =src/config/resource_limits.jl= + =src/middleware/eval.jl= | Boundary invariant not enforced | =ResourceLimits.max_session_history= is representable but not authoritative; live history is bounded by a global constant instead | MEDIUM |
| IS-6 | =src/middleware/eval.jl= + =src/config/server_state.jl= | Cross-structure drift | =active_evals == 0= but =active_eval_tasks= still contains a task after an early error path | HIGH |
| IS-7 | =src/session/manager.jl:clone_named_session!= | Partial-construction state | destination clone is inserted into registry *before* binding copy completes; an exception can leave a partially initialized live session | HIGH |
| IS-8 | =src/middleware/stdin.jl= | Orphaned buffer state | stdin can be successfully enqueued into a session object that is concurrently being closed/replaced and is no longer discoverable | MEDIUM |

** [IS-1] Public mutable =NamedSession= permits invalid field combinations
- Files: =src/session/module_session.jl= (mutable struct + direct fields)
- Why it matters:
  - The intended lifecycle is expressed by helper functions, not by the struct shape itself.
  - Any internal or future external code can write =session.state=, =session.eval_task=, =session.eval_count=, or =session.last_active_at= independently.
- State-space gap:
  - Representable state space includes arbitrary combinations of
    - 3 lifecycle states
    - task present/absent
    - any integer eval counters
  - Valid space is much smaller:
    - Running requires non-nothing =eval_task=
    - Idle and Closed require =eval_task === nothing=
    - Closed should never transition again
- Existing compensating guards:
  - helper functions use =session.lock=
  - tests validate helper behavior
  - no structural prevention against direct mutation
- Pattern mapping:
  - typestate-like encapsulation inside opaque API
  - make mutable fields private by convention/module boundary or split runtime state into smaller atomic records

** [IS-2] =try_begin_eval!= encodes a hidden precondition
- Files: =src/session/manager.jl:try_begin_eval!=
- Invalid state:
  - two callers can invoke =try_begin_eval!= without holding =eval_lock= and observe =ArgumentError= or racey sequencing not modeled by the API contract
- Why it matters:
  - correctness depends on call ordering outside the function signature
  - this is temporal coupling rather than enforced typestate
- Pattern mapping:
  - parse/precondition at API boundary: provide one public helper that acquires =eval_lock= internally
  - keep =try_begin_eval!= internal/private

** [IS-3] Alias replacement creates detached-but-live object graphs
- Files: =src/session/manager.jl:create_named_session!=
- Invalid state:
  - old session object is marked Closed and removed from registry
  - callers holding a reference can still touch its module, history, channel, and locks
  - if the old session was concurrently running, the running eval may continue on an unreachable session object
- Why it matters:
  - this is the clearest shared-mutability smell in the subsystem
  - identity, lifecycle, and reachability stop moving together atomically
- Pattern mapping:
  - replace-same-name should probably be an explicit close-or-error workflow, not silent replacement
  - if replacement remains allowed, synchronize with =eval_lock= and explicitly retire ancillary resources

** [IS-4] Explicit UUID injection can drift alias maps
- Files: =src/session/manager.jl:create_named_session!=
- Invalid state:
  - creating a session with an existing UUID but a different alias replaces =named_sessions[uuid]=
  - old alias cleanup is not performed unless the *new* alias collides
  - multiple aliases can end up resolving to the same replacement session unexpectedly
- Why it matters:
  - lower production risk because explicit UUID injection is documented as test-oriented
  - still a true registry-integrity hole
- Pattern mapping:
  - make explicit-id creation test-only/internal
  - when replacing by UUID, remove prior alias binding transactionally

** [IS-5] Config advertises a history bound that runtime does not honor
- Files: =src/config/resource_limits.jl=, =src/middleware/eval.jl=, =src/session/module_session.jl=
- Invalid state:
  - callers can construct =ResourceLimits(max_session_history=10)=, but session history still clamps at =MAX_SESSION_HISTORY_SIZE=
- Why it matters:
  - config object and live behavior disagree
  - tests currently only verify the constant-based bound
- Pattern mapping:
  - boundary parsing to one authoritative configuration source
  - remove duplicate notion of history bound

** [IS-6] Server eval count and task registry can disagree
- Files: =src/middleware/eval.jl=, =src/config/server_state.jl=
- Invalid state:
  - after task registration, an invalid =module= path returns early with a decrement of =active_evals= but no =unregister_active_eval!=
  - resulting state: counter says 0, task set still contains the task
- Why it matters:
  - shutdown/interrupt logic consumes =active_eval_tasks=
  - stale tasks violate the intended meaning of “currently active evals”
- Pattern mapping:
  - sandwich/FC-IS style resource management: one entry point, one finally path, no early return after partial registration

** [IS-7] Clone registration happens before clone validity is proven
- Files: =src/session/manager.jl:clone_named_session!=
- Invalid state:
  - destination session becomes externally visible before binding-copy loop finishes
  - if =deepcopy= or =Core.eval= fails for some binding, a partial clone remains in registry
- Why it matters:
  - clients can observe a clone that claims to exist but is semantically incomplete
- Pattern mapping:
  - two-phase construction: copy into a private module first, publish to registry only after success

** [IS-8] stdin can target an object that no longer has live registry identity
- Files: =src/middleware/stdin.jl=
- Invalid state:
  - lookup succeeds
  - close/replacement happens
  - stdin still enqueues into the old session channel and returns success based on stale state snapshot
- Why it matters:
  - user-visible acknowledgement may not correspond to future consumability
- Pattern mapping:
  - atomic deliver/validate under stronger session lifecycle coordination

* Mutability and Concurrency Hazard List

| ID | Location | Hazard | Triggering Scenario | Severity |
|-
| HAZ-1 | =src/session/manager.jl:destroy_named_session!= / src/middleware/session_ops.jl:handle_close_session= | Close vs running eval unsynchronized | close removes session without taking =eval_lock= while eval is active or queued | HIGH |
| HAZ-2 | =src/session/manager.jl:clone_named_session!= | Clone vs running eval unsynchronized | clone copies bindings while source session is mutating | HIGH |
| HAZ-3 | =src/session/manager.jl:create_named_session!= | Replace-by-name race | creating same alias during in-flight eval closes old session without coordinating with eval | HIGH |
| HAZ-4 | =src/middleware/stdin.jl= | Snapshot race on stdin classification/delivery | state checked, then input queued after session closes or is replaced | MEDIUM |
| HAZ-5 | =src/middleware/eval.jl= | Early-return resource leak | invalid module path after =register_active_eval!= leaves stale task registration | HIGH |
| HAZ-6 | =src/session/manager.jl:clone_named_session!= | Partial publication | destination published before copy succeeds | HIGH |
| HAZ-7 | =src/middleware/session.jl= / =src/middleware/session_ops.jl= | Session-limit TOCTOU | concurrent requests can both pass =total_session_count= check and exceed limit | MEDIUM |
| HAZ-8 | =src/middleware/eval.jl:_update_history!= | Shared mutable history without dedicated lock | history updates are serialized only indirectly by =eval_lock=; direct readers/writers can race | MEDIUM |

** [HAZ-1] close vs eval race remains the strongest lifecycle hazard
- Files:
  - =src/middleware/session_ops.jl:handle_close_session=
  - =src/session/manager.jl:destroy_named_session!=
- Scenario:
  - Given a named session with a running or queued eval
  - When a =close= request arrives concurrently
  - Then the session is marked Closed and removed from the registry without synchronizing on =eval_lock=
  - And the eval may continue on a detached object or observe closure only indirectly
- Why this matters:
  - It breaks the intuitive invariant that close is the single terminal transition.
  - It also weakens any future formal reasoning about queued-eval outcomes.

** [HAZ-2] clone vs eval race can snapshot moving module state
- Files: =src/session/manager.jl:clone_named_session!=
- Scenario:
  - Given a source named session evaluating code that mutates bindings
  - When =clone= iterates names and copies values without taking =source.eval_lock=
  - Then the clone can observe a mix of old and new bindings
- Impact:
  - clone contract becomes “best effort snapshot,” but that contract is neither stated nor tested.

** [HAZ-3] silent same-name replacement is a concurrency footgun
- Files: =src/session/manager.jl:create_named_session!=
- Scenario:
  - Given session alias =main= is currently in use
  - When another caller creates =main= again
  - Then the old session is closed and removed implicitly
  - And any holders of the old object keep a detached mutable session
- Impact:
  - Identity and liveness are no longer coupled.
  - This is especially risky because the API surface presents create as constructive, not destructive.

** [HAZ-4] stdin acknowledgement is only eventually true
- Files: =src/middleware/stdin.jl=
- Scenario:
  - Given =stdin= snapshots =SessionRunning=
  - When the session closes immediately after the snapshot but before or after =put!=
  - Then the response may say =delivered= although no future eval can consume that input from the registry perspective
- Impact:
  - user-visible success semantics become ambiguous

** [HAZ-5] server-wide task registry leak on invalid module path
- Files: =src/middleware/eval.jl=
- Scenario:
  - Given server state is enabled
  - When eval increments and registers active task
  - And module resolution fails before entering the main =try/finally=
  - Then =active_evals= is decremented but =active_eval_tasks= is not cleaned up
- Impact:
  - shutdown interrupt set may include stale tasks
  - monitoring invariants drift silently

** [HAZ-6] clone publication is not atomic with semantic completeness
- Files: =src/session/manager.jl:clone_named_session!=
- Scenario:
  - Given a source session with a binding that cannot be deeply copied or quoted into =Core.eval=
  - When clone publishes destination before copy finishes
  - Then a visible but incomplete clone can survive an exception path
- Impact:
  - externally observable half-built state

** [HAZ-7] max-session enforcement is check-then-act, not atomic
- Files:
  - =src/middleware/session.jl=
  - =src/middleware/session_ops.jl=
- Scenario:
  - Given total sessions are at =limit - 1=
  - When two requests concurrently pass the count check
  - Then both can create a session and overshoot the configured cap
- Impact:
  - resource-limit invariant is only approximate under concurrency

** [HAZ-8] history protection is emergent rather than explicit
- Files: =src/middleware/eval.jl:_update_history!=, src/session/module_session.jl=
- Scenario:
  - Given future code reads or mutates =session.history= without =eval_lock=
  - When eval completion appends/clamps concurrently
  - Then history ordering/bounds become race-sensitive
- Impact:
  - currently low because normal path serializes evals, but the data structure itself is unguarded

* Edge-Case Discovery Report

Risk Assessment: Safety/security [N], Concurrency [Y], Regulatory [N], Failure cost [M/H]
Boundary 5 (Failure): APPLY — concurrency and lifecycle operations are central to correctness
Boundary 6 (Formal): APPLY (lightweight) — small state machine plus lock/counter invariants justify explicit analysis

** Human / Operator Findings

[HUM-1] HIGH
- Persona/Scenario: sleep-deprived operator debugging a stuck session
- Gap: there is no explicit guarantee for whether =close= waits for, interrupts, or races with a running eval
- Impact: operators cannot predict whether “close the bad session” is safe
- Suggested Scenario:
  - Given a named session with a long-running eval
  - When an operator sends =close=
  - Then the system should specify whether the eval is interrupted, drained, or allowed to finish

[HUM-2] MEDIUM
- Persona/Scenario: client author relying on =stdin= acknowledgement
- Gap: =buffered= vs =delivered= is only a point-in-time classification, not a durability guarantee
- Impact: clients may treat success as stronger than it is
- Suggested Scenario:
  - Given a running eval waiting on stdin
  - When the session closes immediately after a stdin request is accepted
  - Then the contract should state whether the response may still report =delivered=

** Business / Contract Findings

[BIZ-1] HIGH
- Rule: session alias identity should be stable unless explicitly closed/replaced
- Missing Path: abuse/hazard
- Gap: =create_named_session!= silently replaces same-name sessions
- Question: is replacement intended public behavior or only a low-level helper convenience?
- Suggested Scenario:
  - Given alias =main= already exists
  - When a second =new-session= or create path targets =main=
  - Then the system should either reject, explicitly replace, or version the alias

[BIZ-2] HIGH
- Rule: clone should provide a coherent copy contract
- Missing Path: hazard
- Gap: no stated behavior for clone during concurrent mutation
- Suggested Scenario:
  - Given source session S is running code that mutates =x=
  - When =clone= is requested concurrently
  - Then the system should define whether clone blocks, snapshots pre-state, snapshots post-state, or errors

[BIZ-3] HIGH
- Rule: server-wide active eval bookkeeping should be exact
- Missing Path: error
- Gap: invalid-module early return can desynchronize task registry from active count
- Suggested Scenario:
  - Given =module="Main.Nope"=
  - When the request is rejected after task registration
  - Then both active count and active task registry should return to pre-request state

[BIZ-4] MEDIUM
- Rule: history retention should follow configured limits
- Missing Path: boundary/error
- Gap: configured =max_session_history= is not the actual bound
- Suggested Scenario:
  - Given server history limit = 10
  - When a session completes 11 successful stored evals
  - Then only the 10 most recent entries should remain

** Mathematical / Boundary Findings

[MATH-1] HIGH
- Input/Condition: concurrent creators against =max_sessions=
- Boundary: =limit - 1= with two simultaneous creators
- Gap: current check is non-atomic
- Suggested Requirement: creation must be accepted/rejected under one registry lock and one authoritative count snapshot

[MATH-2] MEDIUM
- Input/Condition: explicit UUID replacement path
- Boundary: existing UUID + different alias
- Gap: alias-map cleanup not proven
- Suggested Requirement: for any UUID replacement, old aliases and new aliases must form a 1:1 live mapping afterward

[MATH-3] HIGH
- Input/Condition: clone publication point
- Boundary: exception on kth copied binding out of N
- Gap: visible states include partially populated destination module
- Suggested Requirement: either clone is atomic or partial clone semantics are explicitly documented and surfaced

** Architectural / Contract Findings

[ARCH-1] HIGH
- Interface: =try_begin_eval!=
- Contract Element: precondition
- Gap: caller must already hold =eval_lock=, but that is only in docs/comments
- Suggested Contract: make lock acquisition internal or expose a public wrapper that cannot be miscalled

[ARCH-2] HIGH
- Interface: =destroy_named_session!= / close=
- Contract Element: postcondition
- Gap: “closed” does not currently imply “no eval can still be running on the retired object”
- Suggested Contract: after successful close, either no eval is running, or the response contract must explicitly permit detached completion

[ARCH-3] HIGH
- Interface: =clone_named_session!=
- Contract Element: postcondition
- Gap: no strong guarantee that returned/published clone is a stable snapshot of one source state
- Suggested Contract: clone must either synchronize with evals or declare weaker semantics

[ARCH-4] MEDIUM
- Interface: =stdin=
- Contract Element: invariant
- Gap: a successful stdin response does not guarantee future consumability from a live registry-visible session
- Suggested Contract: define whether stdin success means “accepted into object-local buffer” or “guaranteed reachable by a live session”

** Failure / Formal Findings

[FAIL-1] HIGH
- Failure Mode: stale =active_eval_tasks= entry after request rejection
- Category: bookkeeping / shutdown interference
- Risk: [High / Possible / Hidden]
- Gap: no test asserts count/task-set consistency after early module-resolution failure
- Suggested Mitigation: ensure registration/unregistration are paired in one finally path

[FAIL-2] HIGH
- Failure Mode: detached running eval after same-name replacement or close
- Category: lifecycle race
- Risk: [High / Possible / Hidden]
- Gap: no tests cover replacement/close while source eval is live
- Suggested Mitigation: synchronize retirement with =eval_lock= or weaken/document semantics

[FAIL-3] HIGH
- Failure Mode: partial clone survives copy failure
- Category: atomicity failure
- Risk: [High / Possible / Hidden]
- Gap: no tests inject clone-copy failure after publication
- Suggested Mitigation: publish destination only after successful copy or rollback on failure

[FORM-1] HIGH
- Subsystem: named-session lifecycle
- Property Type: safety
- Gap: desired safety property “closed sessions cannot continue observable work” is not guaranteed by current close path
- Suggested Property: once close succeeds, no future or in-flight eval on that session identity may produce user-visible non-terminal work unless explicitly specified

[FORM-2] HIGH
- Subsystem: clone semantics
- Property Type: linearizability/snapshot safety
- Gap: no linearization point exists for clone relative to source eval mutation
- Suggested Property: clone should correspond to source state at one well-defined instant

[FORM-3] MEDIUM
- Subsystem: server-wide eval accounting
- Property Type: invariant
- Gap: =length(active_eval_tasks) == active_evals[]= is intended but not enforced on all paths
- Suggested Property: registration and counter transitions must be atomic as an abstract resource-acquisition pair

* Explicit Test Gap List

1. =close= vs running eval race
   - No targeted test proves whether close blocks, interrupts, or detaches a running eval.
2. =close= vs queued same-session eval
   - No test for queued requests waiting on =eval_lock= while close happens.
3. =clone= vs running eval snapshot consistency
   - No test verifies whether clone waits for a stable source state.
4. same-name replacement while eval is running
   - No test covers =create_named_session!= replacing an active alias.
5. invalid module path bookkeeping cleanup
   - No test checks =active_eval_tasks= emptiness after module-resolution failure with server state enabled.
6. partial clone rollback on copy failure
   - No test injects a binding whose clone path fails after destination publication.
7. atomic =max_sessions= enforcement under concurrency
   - No test launches concurrent creators at the limit boundary.
8. explicit UUID replacement alias cleanup
   - No test covers =create_named_session!(...; id=existing_uuid)= with old/new alias drift.
9. stdin accepted during concurrent close
   - No test distinguishes object-local buffering from live-session delivery under race.
10. stdin accepted during alias replacement
    - No test covers enqueue into old session object after alias retargeting.
11. history bound obeys =ResourceLimits.max_session_history=
    - Existing tests only cover =MAX_SESSION_HISTORY_SIZE= constant.
12. cross-check invariant between =active_evals= and =active_eval_tasks=
    - No invariant test asserts they match across success, timeout, interrupt, and early error paths.

* Priority Findings and Follow-up Suggestions

** Highest priority for follow-up tickets
1. close/clone synchronization semantics
   - Reason: lifecycle safety and user-visible correctness
   - Files: =src/session/manager.jl=, =src/middleware/session_ops.jl=
2. active-eval bookkeeping exactness
   - Reason: hidden server-state drift affects shutdown and observability
   - Files: =src/middleware/eval.jl=, =src/config/server_state.jl=
3. atomic clone publication / rollback behavior
   - Reason: currently representable half-built sessions
   - Files: =src/session/manager.jl=
4. alias replacement policy
   - Reason: current create path is both constructive and destructive
   - Files: =src/session/manager.jl=, session-creation call sites
5. resource-limit authority for history bounds
   - Reason: config/runtime mismatch
   - Files: =src/config/resource_limits.jl=, =src/middleware/eval.jl=, =src/session/module_session.jl=

* Verdict

Verdict: *NEEDS FOLLOW-UP TICKETS*

Rationale:
- The subsystem is not fundamentally chaotic; the happy path and much of the test suite are strong.
- The remaining issues are mostly not “basic feature missing” problems. They are *semantic integrity* problems at the boundaries of lifecycle, shared mutability, and concurrency.
- The most important next step is not another broad review. It is to decompose the highlighted hazards into small, test-first follow-up tickets for contract decisions and race-focused tests.
