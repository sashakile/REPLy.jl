# Security Model

_Version: 1.1 — 2026-04-17_

## Purpose

Specify the local security posture, resource limit enforcement, audit logging, resilience requirements, and graceful shutdown behavior for the Reply server. Unix socket permission mechanics are defined in `transport/spec.md` (REQ-RPL-041); this spec defines the security-level requirement that only the socket owner can connect. Remote security (TLS, auth middleware) is deferred post-v1.0.

## Requirements

### Requirement: Unix Socket Owner-Only Access
The Unix domain socket SHALL be accessible only to the server's owner UID. The implementation mechanism (umask wrapping, chmod) is specified in `transport/spec.md`. (REQ-RPL-041)

#### Scenario: Non-owner cannot connect to Unix socket
- **WHEN** the server runs on a Unix socket
- **THEN** a process running as a different UID cannot open the socket

### Requirement: Resource Limit Enforcement
The server SHALL enforce all configured `ResourceLimits` fields (see `resource-limits/spec.md` for the complete field table and defaults). Default values apply when not overridden. (REQ-RPL-047a..047i)

#### Scenario: Eval timeout enforced within 50ms
- **WHEN** an eval exceeds `max_eval_time_ms`
- **THEN** an `InterruptException` is sent to the eval task within 50 ms; response is `{"status":["done","error","timeout"]}` (REQ-RPL-047a)

#### Scenario: Eval timeout and manual interrupt collision
- **WHEN** a timeout fires and a manual `interrupt` op arrives simultaneously for the same eval
- **THEN** the first termination cause wins; the second is a no-op. The response reflects the cause that took effect (either `"timeout"` or `"interrupted"`).

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
- **WHEN** a client exceeds `rate_limit_per_min` operations per minute on a single connection
- **THEN** additional requests return `{"status":["done","error"],"err":"Rate limit exceeded"}` (REQ-RPL-047f)

#### Scenario: History entries bounded per session
- **WHEN** `max_history_entries` is reached in a session
- **THEN** the oldest `HistoryEntry` is evicted (REQ-RPL-047h)

#### Scenario: Low rate limit triggers startup warning
- **WHEN** `rate_limit_per_min` is configured below `min_rate_limit_per_min`
- **THEN** the server logs a startup warning (MATH-007)

### Requirement: Audit Logging
The server SHALL maintain an in-memory audit log bounded at 100,000 entries (evict oldest 50,000 when exceeded). If a log path is configured, entries SHALL be appended as newline-delimited JSON; files exceeding 100 MB SHALL be rotated. (FAIL-007)

Each `AuditLog` entry SHALL contain:
- `timestamp` (DateTime)
- `client_id` (UUID — internal connection identifier)
- `session_id` (String or null)
- `operation` (String — the `op` value)
- `user` (String — client identity if authenticated, else empty)
- `source_ip` (String — client address)
- `success` (Bool)
- `error` (String or null — the `err` value on failure)

#### Scenario: Audit entry written per operation
- **WHEN** an eval operation completes
- **THEN** an `AuditLog` entry is written with all fields populated

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

### Requirement: Graceful Shutdown
The server SHALL implement graceful shutdown (REQ-RPL-048) with the following ordered steps:

1. Stop accepting new connections immediately.
2. Interrupt all in-flight evals (best-effort `InterruptException`).
3. Wait up to a configurable grace period (default 5 seconds) for in-flight evals to complete.
4. Close all client connections, flushing pending sends.
5. Remove Unix socket file if applicable.
6. Shut down middleware in reverse stack order.

#### Scenario: Shutdown interrupts in-flight evals
- **WHEN** shutdown is initiated while evals are running
- **THEN** all in-flight evals receive `InterruptException` and the server waits up to the grace period for them to terminate

#### Scenario: Shutdown completes within grace period
- **WHEN** all evals complete or are interrupted within the grace period
- **THEN** the server closes all connections and exits cleanly

#### Scenario: Shutdown proceeds after grace period expires
- **WHEN** evals do not terminate within the grace period
- **THEN** the server closes all connections anyway and exits
