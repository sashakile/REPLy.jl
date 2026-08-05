## MODIFIED Requirements

### Requirement: Resource Limit Enforcement
The server SHALL enforce all configured `ResourceLimits` fields (see `resource-limits/spec.md` for the complete field table and defaults). Default values apply when not overridden. (REQ-RPL-047a..047i)

#### Scenario: Eval timeout enforced on reference hardware
- **WHEN** an eval exceeds `max_eval_time_ms`
- **THEN** on reference hardware the server delivers timeout cancellation and emits `{"status":["done","error","timeout"]}` within 100 ms p99 of the timeout threshold being crossed (REQ-RPL-047a)

#### Scenario: Non-interruptible eval retains accounting after timeout
- **WHEN** an eval exceeds `max_eval_time_ms` due to a non-interruptible operation (tight `ccall`, BLAS, native)
- **THEN** the still-live task is atomically classified as a zombie before the client receives `{"status":["done","error","timeout"]}`
- **AND** it retains exactly one EvalGate permit, active-task registration, and session/resource charge until actual termination

#### Scenario: Timeout races with completion
- **WHEN** the timeout threshold and eval completion occur concurrently
- **THEN** exactly one transition wins and the client receives exactly one terminal response
- **AND** completion cleanup releases the permit, registration, and resource charges exactly once

#### Scenario: Eval timeout and manual interrupt collision
- **WHEN** a timeout fires and a manual `interrupt` op arrives simultaneously for the same eval
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
- **THEN** new evals and queued acquisitions that can no longer progress are rejected with `{"status":["done","error","concurrency-limit-reached"],"err":"Too many concurrent evals"}` within 100 ms p99 on reference hardware
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

## ADDED Requirements

### Requirement: Hard Reclamation Boundary
The server SHALL treat process termination as the only hard reclamation boundary for a non-cooperative in-process eval. A light-session timeout SHALL bound the client response but SHALL NOT claim that execution or resources have been reclaimed.

#### Scenario: Native zombie survives cooperative cancellation
- **WHEN** a native eval ignores timeout and interrupt cancellation
- **THEN** the server retains its accounting until the task actually terminates or the server process terminates
