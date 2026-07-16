## MODIFIED Requirements

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

The ResourceLimits struct SHALL also provide an `unlimited()` constructor that sets all limits to sentinel values indicating no enforcement.

#### Scenario: Unlimited constructor permits everything
- **WHEN** the server starts with `ResourceLimits.unlimited()`
- **THEN** no resource limits are enforced (all operations proceed without check)

#### Scenario: Accessor returns effective limit
- **WHEN** `effective_limit(ctx, :max_sessions, 128)` is called
- **THEN** the value of `ctx.server_state.limits.max_sessions` is returned, or 128 if limits are nil