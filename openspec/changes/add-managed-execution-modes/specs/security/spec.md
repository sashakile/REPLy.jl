---
id: spec
kind: intent
statement: "WHEN execution is admitted, THE server SHALL apply mode-aware deadline and reclamation contracts while preserving live-work accounting."
---

## Constraints

| id | kind | expr | traces_to |
|----|------|------|-----------|
| MODE_LIMITS | invariant | Attached deadlines are cooperative and managed deadlines are independently supervised | [[spec]] |
| LIVE_ACCOUNTING | invariant | A response or cancellation request does not release live execution charges | [[spec]] |

## Model

### States

- `unconfigured`
- `configured`

### Transitions

| id | from | to | guard |
|----|------|----|-------|
| establish_contract | unconfigured | configured | [[spec.MODE_LIMITS]] |
| exercise_contract_1 | configured | configured | [[spec.MODE_LIMITS]] |
| exercise_contract_2 | configured | configured | [[spec.LIVE_ACCOUNTING]] |

## Properties

| id | kind | derives_from | generator | predicate |
|----|------|--------------|-----------|-----------|
| mode_limits_holds | unit | [[spec.MODE_LIMITS]] | `test/e2e/managed_runtime_test.jl` | busy worker still permits bounded timeout and supervisor ping; attached delivery remains cooperative |
| live_accounting_holds | unit | [[spec.LIVE_ACCOUNTING]] | `test/unit/concurrent_eval_test.jl` | retained attached tasks and unreaped managed workers keep charges until confirmed termination |

## MODIFIED Requirements

### Requirement: Resource Limit Enforcement
The server SHALL enforce configured controls according to their governing execution-mode contract (see `resource-limits/spec.md`). Attached timeout cancellation is cooperative; it SHALL NOT claim scheduler-independent response or forced reclamation. Managed deadlines SHALL be supervised outside the worker and meet the execution-management response bound. Memory enforcement SHALL be reported as OS-enforced or unsupported, with required enforcement failing startup when unavailable. Default configuration values apply when not overridden. (REQ-RPL-047a..047i)

#### Scenario: Cooperative attached deadline
- **WHEN** an attached eval exceeds its effective deadline and the scheduler can run the deadline handler
- **THEN** it emits one done/error/timeout terminal and preserves live-work accounting; a non-yielding scheduler has no response-latency guarantee (REQ-RPL-047a)

#### Scenario: Supervised managed deadline
- **WHEN** a submitted managed eval exceeds its effective deadline
- **THEN** the supervisor retires the runtime and emits one timeout/runtime-lost terminal within the execution-management reference bound without waiting for reaping

#### Scenario: Non-interruptible attached eval retains accounting after delivered timeout
- **WHEN** an attached deadline handler runs and an eval exceeds `max_eval_time_ms` due to a non-interruptible operation (tight `ccall`, BLAS, native)
- **THEN** the still-live task is atomically classified as a zombie before the client receives `{"status":["done","error","timeout"]}`
- **AND** it retains exactly one EvalGate permit, active-task registration, and session/resource charge until actual termination

#### Scenario: Timeout races with completion
- **WHEN** an attached eval timeout threshold and completion occur concurrently
- **THEN** exactly one transition wins and the client receives exactly one terminal response
- **AND** completion cleanup releases the permit, registration, and resource charges exactly once

#### Scenario: Eval timeout and manual interrupt collision
- **WHEN** an attached timeout fires and a manual `interrupt` op arrives simultaneously for the same eval
- **THEN** manual interrupt is only an idempotent cancellation request, and observed task termination produces `{"status":["done","interrupted"]}` only if termination is observed before the deadline transition
- **AND** if the deadline transition observes the task live, it classifies the task as a zombie and emits `{"status":["done","error","timeout"]}` even if cancellation was requested
- **AND** the eval emits exactly one terminal response

#### Scenario: Session limit enforced on clone
- **WHEN** `max_sessions` active sessions exist and `clone` is called
- **THEN** server returns `{"status":["done","error","session-limit-reached"],"err":"Session limit reached"}` (REQ-RPL-047c)

#### Scenario: Concurrent eval limit enforced with queue
- **WHEN** `max_concurrent_evals` evals are in flight and a new eval arrives
- **THEN** it queues FIFO up to 2× limit; beyond the queue it is rejected with `{"status":["done","error","concurrency-limit-reached"],"err":"Too many concurrent evals"}` (REQ-RPL-047d)

#### Scenario: Zombie-saturated capacity rejects queued and new evals
- **WHEN** live zombies retain all EvalGate permits
- **THEN** new evals and queued acquisitions that can no longer progress are rejected with `{"status":["done","error","concurrency-limit-reached"],"err":"Too many concurrent evals"}` within 100 ms p99 on reference hardware when the control scheduler can run; managed supervisor control handling does not depend on worker evaluation
- **AND** rejection does not acquire or wait on EvalGate, `eval_lock`, or task completion
- **AND** no queued acquisition remains stranded waiting for zombie termination

#### Scenario: Oversized message closes connection
- **WHEN** a message exceeds `max_message_size`
- **THEN** the connection is closed with an audit-log entry; no response is sent (REQ-RPL-047e)

#### Scenario: Rate limit enforced per connection
- **WHEN** a client exceeds `rate_limit_per_min` operations per minute on a single connection
- **THEN** additional requests return `{"status":["done","error","rate-limited"],"err":"Rate limit exceeded"}` (REQ-RPL-047f)

#### Scenario: History entries bounded per session
- **WHEN** `max_history_entries` is reached in a session
- **THEN** the oldest `HistoryEntry` is evicted (REQ-RPL-047h)

#### Scenario: Low rate limit triggers startup warning
- **WHEN** `rate_limit_per_min` is configured below `min_rate_limit_per_min`
- **THEN** the server logs a startup warning (MATH-007)

#### Scenario: Managed timeout and manual interrupt collision
- **WHEN** completion, effective deadline and the 100 ms cancellation-cessation grace race for the same submitted managed eval
- **THEN** one atomic winner selects completion/interrupted if cessation wins, done/error/timeout/runtime-lost if deadline wins, or done/interrupted/runtime-lost if grace wins
- **AND** a retirement winner invalidates sibling sessions, selects runtime-lost for other pending requests and retains charges until exit; cancellation receipt alone cannot win

### Requirement: Hard Reclamation Boundary
Attached execution SHALL treat application process termination as the forced reclamation boundary and SHALL NOT terminate the externally owned application on timeout or client disconnect. Managed execution SHALL initiate owned worker termination independently of response emission, invalidate its sessions and retain live-worker resource charges until exit is confirmed. Neither mode SHALL claim rollback of external effects.

#### Scenario: Attached native work survives cancellation
- **WHEN** attached work ignores cooperative cancellation
- **THEN** its live accounting remains until real termination and REPLy does not kill the application

#### Scenario: Managed response precedes reaping
- **WHEN** the managed deadline wins but worker exit has not been observed
- **THEN** one timeout/runtime-lost terminal is emitted and the still-live worker remains charged


### Requirement: Orphan Eval Cleanup on Disconnect
When a client disconnects, the server SHALL cancel that connection's in-flight and queued evals using connection-scoped request identity. Attached cancellation SHALL remain cooperative and SHALL NOT kill the application. Managed cancellation SHALL remove unsent work, request cancellation for submitted work and retire the generation if matching cessation is not observed within 100 ms, following execution-management cancellation/deadline arbitration. A disconnected client's terminal SHALL be selected at most once and discarded; surviving clients SHALL receive runtime-lost for nonterminal requests if retirement occurs. (BIZ-008)

#### Scenario: Disconnect cancels running eval
- **WHEN** an attached client disconnects while an eval is running
- **THEN** InterruptException is requested for that connection's eval, live-work accounting remains until actual cessation and the application is never terminated by REPLy

#### Scenario: Managed disconnect affects only its connection before escalation
- **WHEN** a managed client disconnects with both unsent and submitted work and another client reuses the same wire id
- **THEN** only disconnected-client work is cancelled, unsent work never executes and unconfirmed submitted cessation escalates to runtime loss for surviving clients

## Requirements

### Requirement: Resource Limit Enforcement
The server SHALL enforce configured controls according to their governing execution-mode contract (see `resource-limits/spec.md`). Attached timeout cancellation is cooperative; it SHALL NOT claim scheduler-independent response or forced reclamation. Managed deadlines SHALL be supervised outside the worker and meet the execution-management response bound. Memory enforcement SHALL be reported as OS-enforced or unsupported, with required enforcement failing startup when unavailable. Default configuration values apply when not overridden. (REQ-RPL-047a..047i)

#### Scenario: Cooperative attached deadline
- **WHEN** an attached eval exceeds its effective deadline and the scheduler can run the deadline handler
- **THEN** it emits one done/error/timeout terminal and preserves live-work accounting; a non-yielding scheduler has no response-latency guarantee (REQ-RPL-047a)

#### Scenario: Supervised managed deadline
- **WHEN** a submitted managed eval exceeds its effective deadline
- **THEN** the supervisor retires the runtime and emits one timeout/runtime-lost terminal within the execution-management reference bound without waiting for reaping

#### Scenario: Non-interruptible attached eval retains accounting after delivered timeout
- **WHEN** an attached deadline handler runs and an eval exceeds `max_eval_time_ms` due to a non-interruptible operation (tight `ccall`, BLAS, native)
- **THEN** the still-live task is atomically classified as a zombie before the client receives `{"status":["done","error","timeout"]}`
- **AND** it retains exactly one EvalGate permit, active-task registration, and session/resource charge until actual termination

#### Scenario: Timeout races with completion
- **WHEN** an attached eval timeout threshold and completion occur concurrently
- **THEN** exactly one transition wins and the client receives exactly one terminal response
- **AND** completion cleanup releases the permit, registration, and resource charges exactly once

#### Scenario: Eval timeout and manual interrupt collision
- **WHEN** an attached timeout fires and a manual `interrupt` op arrives simultaneously for the same eval
- **THEN** manual interrupt is only an idempotent cancellation request, and observed task termination produces `{"status":["done","interrupted"]}` only if termination is observed before the deadline transition
- **AND** if the deadline transition observes the task live, it classifies the task as a zombie and emits `{"status":["done","error","timeout"]}` even if cancellation was requested
- **AND** the eval emits exactly one terminal response

#### Scenario: Session limit enforced on clone
- **WHEN** `max_sessions` active sessions exist and `clone` is called
- **THEN** server returns `{"status":["done","error","session-limit-reached"],"err":"Session limit reached"}` (REQ-RPL-047c)

#### Scenario: Concurrent eval limit enforced with queue
- **WHEN** `max_concurrent_evals` evals are in flight and a new eval arrives
- **THEN** it queues FIFO up to 2× limit; beyond the queue it is rejected with `{"status":["done","error","concurrency-limit-reached"],"err":"Too many concurrent evals"}` (REQ-RPL-047d)

#### Scenario: Zombie-saturated capacity rejects queued and new evals
- **WHEN** live zombies retain all EvalGate permits
- **THEN** new evals and queued acquisitions that can no longer progress are rejected with `{"status":["done","error","concurrency-limit-reached"],"err":"Too many concurrent evals"}` within 100 ms p99 on reference hardware when the control scheduler can run; managed supervisor control handling does not depend on worker evaluation
- **AND** rejection does not acquire or wait on EvalGate, `eval_lock`, or task completion
- **AND** no queued acquisition remains stranded waiting for zombie termination

#### Scenario: Oversized message closes connection
- **WHEN** a message exceeds `max_message_size`
- **THEN** the connection is closed with an audit-log entry; no response is sent (REQ-RPL-047e)

#### Scenario: Rate limit enforced per connection
- **WHEN** a client exceeds `rate_limit_per_min` operations per minute on a single connection
- **THEN** additional requests return `{"status":["done","error","rate-limited"],"err":"Rate limit exceeded"}` (REQ-RPL-047f)

#### Scenario: History entries bounded per session
- **WHEN** `max_history_entries` is reached in a session
- **THEN** the oldest `HistoryEntry` is evicted (REQ-RPL-047h)

#### Scenario: Low rate limit triggers startup warning
- **WHEN** `rate_limit_per_min` is configured below `min_rate_limit_per_min`
- **THEN** the server logs a startup warning (MATH-007)

#### Scenario: Managed timeout and manual interrupt collision
- **WHEN** completion, effective deadline and the 100 ms cancellation-cessation grace race for the same submitted managed eval
- **THEN** one atomic winner selects completion/interrupted if cessation wins, done/error/timeout/runtime-lost if deadline wins, or done/interrupted/runtime-lost if grace wins
- **AND** a retirement winner invalidates sibling sessions, selects runtime-lost for other pending requests and retains charges until exit; cancellation receipt alone cannot win

### Requirement: Hard Reclamation Boundary
Attached execution SHALL treat application process termination as the forced reclamation boundary and SHALL NOT terminate the externally owned application on timeout or client disconnect. Managed execution SHALL initiate owned worker termination independently of response emission, invalidate its sessions and retain live-worker resource charges until exit is confirmed. Neither mode SHALL claim rollback of external effects.

#### Scenario: Attached native work survives cancellation
- **WHEN** attached work ignores cooperative cancellation
- **THEN** its live accounting remains until real termination and REPLy does not kill the application

#### Scenario: Managed response precedes reaping
- **WHEN** the managed deadline wins but worker exit has not been observed
- **THEN** one timeout/runtime-lost terminal is emitted and the still-live worker remains charged


### Requirement: Orphan Eval Cleanup on Disconnect
When a client disconnects, the server SHALL cancel that connection's in-flight and queued evals using connection-scoped request identity. Attached cancellation SHALL remain cooperative and SHALL NOT kill the application. Managed cancellation SHALL remove unsent work, request cancellation for submitted work and retire the generation if matching cessation is not observed within 100 ms, following execution-management cancellation/deadline arbitration. A disconnected client's terminal SHALL be selected at most once and discarded; surviving clients SHALL receive runtime-lost for nonterminal requests if retirement occurs. (BIZ-008)

#### Scenario: Disconnect cancels running eval
- **WHEN** an attached client disconnects while an eval is running
- **THEN** InterruptException is requested for that connection's eval, live-work accounting remains until actual cessation and the application is never terminated by REPLy

#### Scenario: Managed disconnect affects only its connection before escalation
- **WHEN** a managed client disconnects with both unsent and submitted work and another client reuses the same wire id
- **THEN** only disconnected-client work is cancelled, unsent work never executes and unconfirmed submitted cessation escalates to runtime loss for surviving clients
