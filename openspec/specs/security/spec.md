# Security Model

## Purpose

Specify the local security posture (Unix socket permissions, umask), resource limits enforcement, audit logging, and resilience requirements for the Reply server. Remote security (TLS, auth middleware) is deferred post-v1.0.

## Requirements

### Requirement: Unix Socket Local Security
The Unix domain socket SHALL be created with owner-only permissions (`0o600`) via a `umask(0o077)` wrapper before `listen()`, providing owner-only access and closing the permission race window. (REQ-RPL-041)

#### Scenario: Non-owner cannot connect to Unix socket
- **WHEN** the server runs on a Unix socket with `0o600` permissions
- **THEN** a process running as a different UID cannot open the socket

### Requirement: Resource Limit Enforcement
The server SHALL enforce all configured `ResourceLimits` fields. Default values apply when not overridden. (REQ-RPL-047a..047i)

#### Scenario: Eval timeout enforced within 50ms
- **WHEN** an eval exceeds `max_eval_time_ms`
- **THEN** an `InterruptException` is sent to the eval task within 50 ms; response is `{"status":["done","error","timeout"]}` (REQ-RPL-047a)

#### Scenario: Session limit enforced on clone
- **WHEN** `max_sessions` active sessions exist and `clone` is called
- **THEN** server returns `{"status":["done","error"],"err":"Session limit reached"}` (REQ-RPL-047c)

#### Scenario: Concurrent eval limit enforced with queue
- **WHEN** `max_concurrent_evals` evals are in flight and a new eval arrives
- **THEN** it queues FIFO up to 2× limit; beyond the queue it is rejected with `"err":"Too many concurrent evals"` (REQ-RPL-047d)

#### Scenario: Oversized message closes connection
- **WHEN** a message exceeds `max_message_size`
- **THEN** the connection is closed with an audit-log entry; no response is sent (REQ-RPL-047e)

#### Scenario: Rate limit enforced per connection
- **WHEN** a client exceeds `rate_limit_per_min` operations per minute
- **THEN** additional requests return `{"status":["done","error"],"err":"Rate limit exceeded"}` (REQ-RPL-047f)

#### Scenario: History entries bounded per session
- **WHEN** `max_history_entries` is reached in a session
- **THEN** the oldest `HistoryEntry` is evicted (REQ-RPL-047h)

#### Scenario: Low rate limit triggers startup warning
- **WHEN** `rate_limit_per_min` is configured below `min_rate_limit_per_min`
- **THEN** the server logs a startup warning (MATH-007)

### Requirement: Audit Logging
The server SHALL maintain an in-memory audit log bounded at 100,000 entries (evict oldest 50,000 when exceeded). If a log path is configured, entries SHALL be appended as newline-delimited JSON; files exceeding 100 MB SHALL be rotated. (FAIL-007)

#### Scenario: Audit entry written per operation
- **WHEN** an eval operation completes
- **THEN** an `AuditLog` entry is written with timestamp, operation, session ID, and success status

#### Scenario: In-memory log bounded at 100k entries
- **WHEN** the in-memory audit log reaches 100,000 entries
- **THEN** the oldest 50,000 are evicted

#### Scenario: Log file rotated at 100 MB
- **WHEN** the audit log file exceeds 100 MB
- **THEN** it is renamed to `.1` and a new file is started

### Requirement: Orphan Eval Cleanup on Disconnect
When a client disconnects, the server SHALL interrupt all in-flight evals for sessions that were active on that connection. (BIZ-008)

#### Scenario: Disconnect cancels running eval
- **WHEN** a client disconnects while an eval is running
- **THEN** `InterruptException` is sent to the eval task; it does not run indefinitely producing output to a closed channel

### Requirement: Per-Task Stdout/Stderr Capture
The eval implementation SHALL use task-scoped `redirect_stdout`/`redirect_stderr` (requiring Julia ≥ 1.11) to prevent cross-session stdout leakage under concurrent eval. (§13.3, §2.4)

#### Scenario: Concurrent evals do not leak output
- **WHEN** two sessions eval `println` concurrently
- **THEN** each session's `out` chunks arrive in its own response stream only

### Requirement: send_response Resilient to Closed Channel
`send_response` SHALL silently discard messages if the client's send channel is closed. It SHALL NOT propagate `InvalidStateException`. (ARCH-002)

#### Scenario: Response silently discarded after disconnect
- **WHEN** a client disconnects while an eval is still producing output
- **THEN** the server does not crash; output is silently dropped
