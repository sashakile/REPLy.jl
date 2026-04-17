# Session Management

_Version: 1.1 — 2026-04-17_

## Purpose

Specify light session isolation via anonymous Julia Modules, session lifecycle (CREATED → ACTIVE → EVAL_RUNNING → DESTROYED), idle timeout, ephemeral sessions, FIFO eval serialization, and Revise.jl integration. Light sessions are the primary session type for v1.0.

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
A new light session SHALL be created within 10 ms p99 on reference hardware (see `project.md` for reference hardware definition). (REQ-RPL-032)

#### Scenario: Session creation is low-latency
- **WHEN** a `clone` request is sent on reference hardware
- **THEN** the `new-session` response arrives within 10 ms (p99)

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
A request without a `session` field SHALL trigger ephemeral session handling: a transient light session is created, used, and destroyed after the response stream terminates. The ephemeral session ID is NOT returned to the client. (REQ-RPL-035)

#### Scenario: Ephemeral eval leaves no persistent session
- **WHEN** `eval` is sent without a `session` field and completes
- **THEN** `ls-sessions` does not include that session after completion

#### Scenario: Ephemeral sessions count against max_sessions
- **WHEN** `max_sessions` is reached by persistent sessions
- **THEN** ephemeral requests are rejected with `"err":"Session limit reached"` (REQ-RPL-035b)

#### Scenario: Ephemeral evals count against max_concurrent_evals
- **WHEN** `max_concurrent_evals` is reached
- **THEN** new ephemeral evals are rejected (REQ-RPL-035c)

#### Scenario: Ephemeral evals are not interruptible
- **WHEN** an ephemeral eval is running
- **THEN** there is no mechanism to interrupt it because the session ID is not returned to the client. The eval terminates only via completion, timeout, or client disconnect.

### Requirement: Ephemeral Module Reuse
To prevent unbounded memory growth, implementations SHALL reuse a bounded pool of anonymous modules for ephemeral sessions. After eval completes, bindings are cleared and the module returned to the pool, bounded at `max_concurrent_evals`. (REQ-RPL-035)

#### Scenario: Module pool prevents memory growth
- **WHEN** many ephemeral evals complete over time
- **THEN** memory growth from module creation is bounded by the pool size

### Requirement: Session Lifecycle State Machine
Every session SHALL occupy exactly one of `CREATED`, `ACTIVE`, `EVAL_RUNNING`, or `DESTROYED`. All transitions SHALL be atomic with respect to `SessionManager.lock`. (REQ-RPL-038)

#### Scenario: State transitions are atomic
- **WHEN** `close` and `clone` (same parent) race
- **THEN** exactly one wins; the other receives `session-not-found`

#### Scenario: close acquires eval_mutex before destroying
- **WHEN** `close` is called on a session with a queued eval
- **THEN** the queued eval finds the session removed and returns `session-not-found` (REQ-RPL-018b)

### Requirement: Revise.jl Integration
The server SHALL provide a `PreEvalHook` that calls `Revise.revise()` before every eval when Revise.jl is loaded, matching how Revise hooks into the standard REPL. (REQ-RPL-060)

#### Scenario: Revise called before eval picks up changes
- **WHEN** Revise.jl is loaded and a source file has been modified
- **THEN** the PreEvalHook calls `Revise.revise()` before the next eval, loading the changes
