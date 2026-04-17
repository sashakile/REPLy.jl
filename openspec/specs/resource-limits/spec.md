# Resource Limits

_Version: 1.0 — 2026-04-17_

## Purpose

Define the `ResourceLimits` configuration struct that governs server-wide and per-session resource constraints. Individual capability specs reference these fields when specifying enforcement behavior; this spec is the single source of truth for field names, types, and default values.

## Requirements

### Requirement: ResourceLimits Configuration Struct
The server SHALL accept a `ResourceLimits` configuration with the following fields and defaults. All limits SHALL be enforced as specified by their governing capability specs. (REQ-RPL-047)

| Field | Type | Default | Governing Spec | Req ID |
|---|---|---|---|---|
| `max_eval_time_ms` | Int | 60,000 (60 s) | security | REQ-RPL-047a |
| `max_memory_mb` | Int | 2,048 (2 GB) | security | REQ-RPL-047b |
| `max_sessions` | Int | 100 | security | REQ-RPL-047c |
| `max_concurrent_evals` | Int | 10 | security | REQ-RPL-047d |
| `max_message_size` | Int (bytes) | 10,485,760 (10 MB) | security | REQ-RPL-047e |
| `rate_limit_per_min` | Int | 600 | security | REQ-RPL-047f |
| `session_idle_timeout_s` | Int | 3,600 (1 hour) | session-management | REQ-RPL-034 |
| `max_history_entries` | Int | 10,000 (per session) | session-management | REQ-RPL-047h |
| `max_value_repr_bytes` | Int (bytes) | 1,048,576 (1 MB) | core-operations | REQ-RPL-047i |
| `max_id_length` | Int | 256 | protocol | REQ-RPL-001b |
| `min_rate_limit_per_min` | Int | 10 (informative) | security | MATH-007 |
| `max_stdin_buffer` | Int | 16 | core-operations | REQ-RPL-017b |

#### Scenario: Default limits applied when unconfigured
- **WHEN** the server starts with no explicit `ResourceLimits`
- **THEN** all fields use the defaults from the table above

#### Scenario: Individual fields overridable
- **WHEN** the server starts with `ResourceLimits(max_sessions=128)`
- **THEN** `max_sessions` is 128 and all other fields retain their defaults
