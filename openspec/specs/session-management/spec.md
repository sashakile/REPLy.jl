---
id: spec
kind: intent
statement: "WHEN a client creates or addresses a session, THE server SHALL isolate bindings per anonymous module, serialize same-session evals FIFO, bound and reuse ephemeral session modules, close idle and ephemeral sessions automatically, and transition lifecycle states atomically."
---

## Constraints

| id | kind | expr | traces_to |
|----|------|------|-----------|
| SESSION_BINDING_ISOLATION | invariant | every light session is backed by its own anonymous `Module`, so two concurrent evals against different sessions cannot observe each other's bindings | [[spec]] |
| SAME_SESSION_EVAL_FIFO | invariant | at most one `Core.eval` is in flight per light session at any time and concurrent eval requests within a session execute in submission order | [[spec]] |
| EVAL_TASK_VISIBILITY | invariant | `session.eval_task` is assigned to the running task before any eval code begins executing and remains non-nothing while the eval executes, so concurrent interrupt reads observe it | [[spec]] |
| SESSION_CREATION_LATENCY | invariant | a new light session is created within 10 ms p99 on reference hardware on an otherwise idle server | [[spec]] |
| SESSION_TYPE_SELECTION | invariant | a Heavy session is created only when `clone` includes `"type":"heavy"` AND Malt.jl is loaded; every other request creates a Light session, and a heavy request without Malt.jl is rejected with `{"status":["done","error"],"err":"Heavy sessions require Malt.jl"}` | [[spec]] |
| IDLE_SWEEP | invariant | the background sweep closes sessions idle longer than `session_idle_timeout_s` (subsequent requests receive `session-not-found`) and skips sessions with an in-flight eval until the eval completes | [[spec]] |
| EPHEMERAL_LIFECYCLE | invariant | session-bearing execution operations omitting the `session` field (v1.0: `eval`, `load-file`) run in a transient light session that is destroyed after the response stream terminates, whose ID is never returned to the client, and whose creation is rejected with `session-limit-reached` when `max_sessions` is hit and its eval is rejected with `concurrency-limit-reached` when `max_concurrent_evals` is hit and the bounded queue is full; ephemeral evals are not interruptible because no client-visible handle exists | [[spec]] |
| MODULE_POOL | invariant | after an ephemeral eval completes its bindings are cleared and the module is returned to a bounded reuse pool (bounded at `max_concurrent_evals`), so memory growth from module creation is bounded and cleared bindings raise `UndefVarError` again; modules that cannot be fully cleared (pre-1.11 Julia without `Base.delete_binding`, or holding `const` bindings) are dropped instead of pooled, preserving non-persistence semantics | [[spec]] |
| LIFECYCLE_ATOMICITY | invariant | every session occupies exactly one of `CREATED`, `ACTIVE`, `EVAL_RUNNING`, or `DESTROYED`; all transitions are atomic under `SessionManager.lock`; the first atomic transition out of `EVAL_RUNNING` wins against competing close/timeout/interrupt terminals and later termination attempts are no-ops; a `close` that destroys a session makes queued evals observe `session-not-found` | [[spec]] |
| REVISE_PREEVAL_HOOK | invariant | a `PreEvalHook` calls `Revise.revise()` before every named-session eval when Revise.jl is loaded | [[spec]] |

## Model

### States

- `active`
- `eval_running`
- `destroyed`

### Transitions

| id | from | to | guard |
|----|------|----|-------|
| begin_eval | active | eval_running | [[spec.SAME_SESSION_EVAL_FIFO]] |
| end_eval | eval_running | active | [[spec.LIFECYCLE_ATOMICITY]] |
| terminate_eval | eval_running | active | [[spec.LIFECYCLE_ATOMICITY]] |
| sweep_close | active | destroyed | [[spec.IDLE_SWEEP]] |
| close_session | active | destroyed | [[spec.LIFECYCLE_ATOMICITY]] |
| destroy_ephemeral | active | destroyed | [[spec.EPHEMERAL_LIFECYCLE]] |

## Properties

| id | kind | derives_from | generator | predicate |
|----|------|--------------|-----------|-----------|
| binding_isolation_holds | unit | [[spec.SESSION_BINDING_ISOLATION]] | `test/unit/session_management_spec_test.jl` | an eval of `x` in session B raises UndefVarError after session A evaluated `x = 42`, and concurrent sessions run in parallel so B's fast eval completes while A's 2-second eval is still in flight |
| fifo_serialization_holds | unit | [[spec.SAME_SESSION_EVAL_FIFO]] | `test/unit/session_management_spec_test.jl` | two evals submitted concurrently to one session log their execution markers in submission order: the queued eval cannot overtake the sleeping one |
| eval_task_visible_during_eval | unit | [[spec.EVAL_TASK_VISIBILITY]] | `test/unit/session_management_spec_test.jl` | a concurrent poll observes a non-nothing `session.eval_task` during a running eval and the interrupt lands on it, returning `interrupted` naming the session |
| session_creation_p99_under_10ms | unit | [[spec.SESSION_CREATION_LATENCY]] | `test/unit/session_management_spec_test.jl` | the p99 latency of 300 ephemeral session creations is below 10 ms |
| session_type_selection_holds | unit | [[spec.SESSION_TYPE_SELECTION]] | `test/unit/session_management_spec_test.jl` | `new-session` without a type creates a light non-trusted anonymous-module session, and `clone` with `type":"heavy"` returns exactly `{"status":["done","error"],"err":"Heavy sessions require Malt.jl"}` without creating the destination |
| idle_sweep_skips_running | unit | [[spec.IDLE_SWEEP]] | `test/unit/session_management_spec_test.jl` | the sweep removes an idle session (later requests get session-not-found), skips a session in EVAL_RUNNING regardless of age, and sweeps it after the eval ends |
| ephemeral_not_persistent | unit | [[spec.EPHEMERAL_LIFECYCLE]] | `test/unit/session_management_spec_test.jl` | an ephemeral eval returns its value without a session field, `ls-sessions` stays empty, over-limit ephemeral requests carry the specified status flags, and an interrupt without a session field errors instead of reaching any eval |
| module_pool_bounded_and_cleared | unit | [[spec.MODULE_POOL]] | `test/unit/session_management_spec_test.jl` | on Julia 1.11+ a destroyed ephemeral module is cleared (old bindings raise UndefVarError), returned to the pool, reused verbatim by the next ephemeral session; pre-1.11 modules that cannot be cleared are dropped (next session gets a fresh module); the pool never exceeds its capacity |
| racing_terminals_resolve_once | unit | [[spec.LIFECYCLE_ATOMICITY]] | `test/unit/session_management_spec_test.jl` | close and clone racing on one session resolve exactly once across repeated trials, a queued eval reports session-not-found after close, and interrupt/close racing a running eval both complete with a later interrupt a no-op session-not-found |
| revise_hook_runs_before_eval | unit | [[spec.REVISE_PREEVAL_HOOK]] | `test/unit/session_management_spec_test.jl` | a mocked Revise.revise() registered under the authentic PkgId runs exactly once before each named-session eval executes |

# Session Management

_Version: 1.1 — 2026-04-17_

## Purpose

Specify light session isolation via anonymous Julia Modules, session lifecycle including quarantine and detached cleanup, idle timeout, ephemeral sessions, FIFO eval serialization, and Revise.jl integration. Light sessions are the primary session type for v1.0.
## Requirements
### Requirement: Light Session Isolation
A light session SHALL use a separate anonymous `Module` per session. Two concurrent eval requests against two different sessions SHALL NOT observe each other's bindings. (REQ-RPL-030)

#### Scenario: Binding isolation between sessions
- **WHEN** session A evaluates `x = 42` and session B evaluates `x`
- **THEN** session B raises `UndefVarError` (it cannot see session A's `x`)

#### Scenario: Concurrent sessions run in parallel
- **WHEN** session A runs `sleep(2)` and session B runs `1+1` concurrently
- **THEN** session B's result arrives before session A's completes

### Requirement: Light Session Eval Serialization
Concurrent eval requests within the same light session SHALL be serialized in FIFO order. Only one `Core.eval` is in flight per light session at any time. (REQ-RPL-031)

> **Implementation guidance:** A `Channel{Nothing}(1)` provides FIFO fairness guarantees that `ReentrantLock` does not.

#### Scenario: Queued evals execute in FIFO order
- **WHEN** two eval requests arrive for the same session without waiting
- **THEN** they complete in submission order

### Requirement: eval_task Assignment Before Execution
`session.eval_task` SHALL be assigned to the current task before any eval code begins executing, so concurrent interrupt reads see a non-nothing task. (REQ-RPL-031b)

#### Scenario: Interrupt sees non-nothing eval_task
- **WHEN** an interrupt arrives during eval
- **THEN** `session.eval_task` is non-nil throughout the eval's execution

### Requirement: Light Session Creation Time
A new light session SHALL be created within 10 ms p99 on reference hardware (see `project.md` for reference hardware definition), measured on an otherwise idle server using a benchmark harness that issues repeated session-creation requests against the default middleware stack. (REQ-RPL-032)

#### Scenario: Session creation is low-latency
- **WHEN** repeated `clone` requests are sent on reference hardware to an otherwise idle server
- **THEN** the `new-session` response latency meets the 10 ms p99 target

### Requirement: Session Type Selection
The server SHALL create a Heavy session only when `clone` includes `"type":"heavy"` AND Malt.jl is loaded; in all other cases it SHALL create a Light session. (REQ-RPL-033)

> **Note:** Heavy sessions use OS-process isolation via Malt.jl. Their full behavioral spec is deferred post-v1.0. For v1.0, the server SHALL reject `"type":"heavy"` if Malt.jl is not loaded, returning `{"status":["done","error"],"err":"Heavy sessions require Malt.jl"}`.

#### Scenario: Default type is light
- **WHEN** `clone` omits `type`
- **THEN** a light session is created

#### Scenario: Heavy session without Malt.jl rejected
- **WHEN** `clone` includes `"type":"heavy"` but Malt.jl is not loaded
- **THEN** server returns `{"status":["done","error"],"err":"Heavy sessions require Malt.jl"}`

### Requirement: Session Idle Timeout
Sessions SHALL be automatically closed after `session_idle_timeout_s` seconds of inactivity (default 3600 s; see `resource-limits/spec.md`). A background idle sweep runs every 60 seconds. (REQ-RPL-034)

#### Scenario: Idle session closed by sweep
- **WHEN** a session has no activity for longer than `session_idle_timeout_s`
- **THEN** the idle sweep closes it; subsequent requests return `session-not-found`

#### Scenario: In-flight eval prevents idle close
- **WHEN** the idle sweep runs while a session has an active eval task
- **THEN** the session is skipped until the eval completes (REQ-RPL-034b)

### Requirement: Ephemeral Sessions
For session-bearing execution operations that omit the `session` field (for v1.0: `eval` and `load-file`), the server SHALL trigger ephemeral session handling: a transient light session is created, used, and destroyed after the eval task actually terminates. A terminal timeout response SHALL NOT destroy a still-live ephemeral session. The ephemeral session ID is NOT returned to the client. (REQ-RPL-035)

#### Scenario: Ephemeral eval leaves no persistent session
- **WHEN** `eval` is sent without a `session` field and completes
- **THEN** `ls-sessions` does not include that session after completion

#### Scenario: Ephemeral sessions count against max_sessions
- **WHEN** `max_sessions` is reached by persistent sessions
- **THEN** ephemeral requests are rejected with `{"status":["done","error","session-limit-reached"],"err":"Session limit reached"}` (REQ-RPL-035b)

#### Scenario: Ephemeral evals count against max_concurrent_evals
- **WHEN** `max_concurrent_evals` is reached and the bounded queue is full
- **THEN** new ephemeral evals are rejected with `{"status":["done","error","concurrency-limit-reached"],"err":"Too many concurrent evals"}` (REQ-RPL-035c)

#### Scenario: Ephemeral evals are not interruptible
- **WHEN** an ephemeral eval is running
- **THEN** there is no mechanism to interrupt it because the session ID is not returned to the client. The eval terminates only via completion, timeout cancellation, client disconnect cancellation, or process termination.

#### Scenario: Ephemeral zombie remains accounted
- **WHEN** an ephemeral eval returns a timeout response while its task remains live
- **THEN** its hidden session, active-task registration, EvalGate permit, and `max_sessions` charge remain until actual task termination

#### Scenario: Ephemeral zombie eventually cleans up
- **WHEN** an ephemeral zombie later terminates
- **THEN** completion cleanup deregisters it, releases its permit and session charge, and tears down its module exactly once

### Requirement: Ephemeral Module Reuse
To prevent unbounded memory growth, implementations SHALL reuse a bounded pool of anonymous modules for ephemeral sessions. After eval completes, bindings are cleared and the module returned to the pool, bounded at `max_concurrent_evals`. (REQ-RPL-035d)

#### Scenario: Module pool prevents memory growth
- **WHEN** many ephemeral evals complete over time
- **THEN** memory growth from module creation is bounded by the pool size

### Requirement: Session Lifecycle State Machine
Every named session object SHALL occupy exactly one of `CREATED`, `ACTIVE`, `EVAL_RUNNING`, `QUARANTINED`, internal `DETACHED`, or `DESTROYED`. Zombie classification SHALL transition the object irreversibly to `QUARANTINED`; task termination SHALL NOT restore it to `ACTIVE`. Close of an `EVAL_RUNNING` or `QUARANTINED` object with a live task SHALL transition it to `DETACHED`, atomically remove its alias from discovery, and retain its accounting. Actual task termination SHALL perform object-identity-keyed teardown and transition `DETACHED` to `DESTROYED` exactly once. Close of a `QUARANTINED` object whose zombie has already terminated SHALL atomically remove its alias, perform normal teardown exactly once, and transition directly to `DESTROYED` without entering `DETACHED`. All transitions SHALL be atomic with respect to `SessionManager.lock`. (REQ-RPL-038)

#### Scenario: State transitions are atomic
- **WHEN** `close` and `clone` (same parent) race
- **THEN** exactly one wins; the other receives `session-not-found`

#### Scenario: Close removes discovery without eval lock
- **WHEN** `close` targets a session with a running or queued eval
- **THEN** close transitions the live object to `DETACHED`, atomically removes it from discovery, and returns within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion
- **AND** queued operations wake and return `session-not-found` without executing

#### Scenario: Close tears down a terminated quarantined session immediately
- **WHEN** `close` targets a quarantined session whose zombie task has already terminated and whose completion accounting has been released
- **THEN** close atomically removes the session from discovery, performs normal teardown exactly once, and transitions `QUARANTINED` directly to `DESTROYED`
- **AND** it does not enter `DETACHED` or wait for another task-completion event
- **AND** it returns within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion

#### Scenario: Close timeout and interrupt resolve one eval response
- **WHEN** `close`, timeout, and `interrupt` race against the same running eval
- **THEN** close only detaches discovery and interrupt only requests cancellation; neither determines the eval terminal result
- **AND** observed task termination determines interrupted completion only if it precedes the deadline, otherwise a task live at the deadline becomes a zombie and yields timeout
- **AND** exactly one eval terminal response is emitted and completion cleanup runs exactly once

#### Scenario: Timeout and close retain hidden accounting
- **WHEN** timeout quarantines a live eval while close concurrently removes its named session from discovery
- **THEN** the hidden session continues to count against `max_sessions` until actual task termination
- **AND** close does not acquire or wait on `eval_lock`, EvalGate, or task completion

#### Scenario: Alias reuse is safe from late cleanup
- **WHEN** a closed session alias is reused for a new session before the old hidden task terminates
- **THEN** alias lookup resolves the replacement and the old closed eval is not recoverable through the alias
- **AND** old-task cleanup is keyed by old object identity and cannot inspect, remove, or mutate the replacement

#### Scenario: Interrupt request follows current alias resolution
- **WHEN** an `interrupt` request's `session` field names an alias that was reused after the old session became `DETACHED`
- **THEN** the `session` field resolves only to the replacement session and the request cannot reach the old detached object
- **AND** if the request's `interrupt-id` eval ID filter matches the old detached eval rather than an eval in the replacement session, the request is an idempotent no-op

### Requirement: Revise.jl Integration
The server SHALL provide a `PreEvalHook` that calls `Revise.revise()` before every eval when Revise.jl is loaded, matching how Revise hooks into the standard REPL. (REQ-RPL-060)

#### Scenario: Revise called before eval picks up changes
- **WHEN** Revise.jl is loaded and a source file has been modified
- **THEN** the PreEvalHook calls `Revise.revise()` before the next eval, loading the changes

### Requirement: Permanent Named-Session Quarantine
A named session object whose eval becomes a zombie SHALL remain permanently quarantined unless close transitions it to `DETACHED`, including after the eval task terminates. Normal session-targeting operations and `stdin` SHALL return `session-quarantined` within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion. Best-effort idempotent `interrupt` and close with the same no-wait response bound SHALL remain allowed.

#### Scenario: Normal operation rejects quarantined session without waits
- **WHEN** an eval, load-file, complete, lookup, clone-from, or other normal session-targeting operation targets a quarantined session
- **THEN** it returns `session-quarantined` within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion

#### Scenario: Stdin rejects quarantined session without waits
- **WHEN** `stdin` targets a quarantined session
- **THEN** it returns `session-quarantined` within 100 ms p99 on reference hardware without buffering input or acquiring or waiting on `eval_lock`, EvalGate, or task completion

#### Scenario: Interrupt remains best-effort and idempotent
- **WHEN** `interrupt` targets a quarantined session before or after its zombie terminates
- **THEN** it returns within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion, attempts cancellation only if the task remains live, and repeated requests have no additional effect

#### Scenario: Quarantine persists after termination
- **WHEN** a named zombie task terminates and completion accounting is released
- **THEN** its named session remains quarantined until close removes it from discovery under the no-wait 100 ms p99 response contract

#### Scenario: Queued session operation observes quarantine
- **WHEN** an operation queued before timeout wakes after the session becomes quarantined
- **THEN** it returns `session-quarantined` within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion, and does not execute

#### Scenario: Close is bounded and idempotent
- **WHEN** `close` targets a quarantined session one or more times
- **THEN** the first call atomically removes discovery and returns within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion
- **AND** if the zombie remains live, it transitions the object to `DETACHED` and leaves object-identity-keyed cleanup deferred until termination
- **AND** if the zombie already terminated, it performs normal teardown exactly once and transitions the object directly to `DESTROYED`
- **AND** later calls return `session-not-found` within the same bound without disturbing completed or deferred cleanup
