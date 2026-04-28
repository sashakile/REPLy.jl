# Security Context

Scope: resource limits, rate limiting, audit logging, and Unix socket
access control. These are the server's protection mechanisms.

---

## Entities & Value Objects

| Term | Definition |
|------|-----------|
| **Resource Limits** | Immutable configuration struct holding all quotas and rate-limit parameters. Created at server startup; never mutated at runtime. |
| **Server State** | Shared mutable server-wide counters (active eval count, active eval tasks). Updated atomically as evals start and finish. |
| **Max Eval Time** (`max_eval_time_ms`) | Wall-clock deadline per eval. Default: 60,000 ms. Enforced on the *reference hardware* baseline. |
| **Max Sessions** (`max_sessions`) | Total concurrent sessions allowed (ephemeral + named combined). Default: 100. |
| **Max Concurrent Evals** (`max_concurrent_evals`) | In-flight evaluations allowed server-wide. Default: 10. Enforced via a bounded queue with capacity `2 × max_concurrent_evals`. |
| **Bounded Eval Queue** | Queue for evals waiting to run. Capacity = `2 × max_concurrent_evals`. Requests exceeding this are rejected with `concurrency-limit-reached`. Prevents starvation without unbounded memory growth. |
| **Max Message Size** (`max_message_size`) | Byte limit on inbound messages. Default: 10 MB. Connection is closed if exceeded. |
| **Rate Limit** (`rate_limit_per_min`) | Max requests **per connection** per 60-second sliding window. Default: 600. Tracked independently for every TCP/Unix connection; not a server-wide aggregate. |
| **Max Value Repr** (`max_value_repr_bytes`) | Truncation threshold for eval result strings. Default: 1 MB. |
| **Max History** (`max_history_entries`) | Entries kept per session's eval history. Default: 1,000 (constant `MAX_SESSION_HISTORY_SIZE`). Oldest evicted when full. |
| **Max Stdin Buffer** (`max_stdin_buffer`) | Pending stdin lines buffered per session when no eval is blocking. Default: 16. |
| **Session Idle Timeout** (`session_idle_timeout_s`) | Seconds of inactivity after which a session is auto-closed. Default: 3,600 (1 hour). |
| **Audit Log Entry** | Record of a single operation: timestamp, client UUID, session ID, op name, user, source IP, success flag, error message. |
| **Audit Log** | In-memory bounded vector of `AuditLogEntry`. Rotates to a file when configured. Max 100,000 in-memory entries; rotate files at 100 MB. |
| **Auth Token** | Secret string for client authentication. Comparison must be constant-time to prevent timing attacks. (Post-v1.0 feature.) |
| **Unix Socket Permissions** | File mode `0o600` (owner-only) applied via umask wrapping. Prevents brief world-readable race at socket creation. |
| **Reference Hardware** | The baseline machine for which limits are defined: Linux x86_64, 4+ cores (PassMark ≥ 2,500), ≥ 8 GB RAM, SSD, Julia 1.11. Timeout guarantees are calibrated to this. |

## Operations (verbs)

| Term | Definition |
|------|-----------|
| **Enforce Timeout** | Interrupt eval after `max_eval_time_ms` on reference hardware; emit `status: ["done","error","timeout"]`. |
| **Enforce Session Limit** | Reject `clone` if `total_session_count >= max_sessions`; return `session-limit-reached`. |
| **Enforce Concurrency Limit** | Queue evals up to `2 × max_concurrent_evals`; reject excess with `concurrency-limit-reached`. |
| **Enforce Message Size** | Measure inbound message byte length; close connection if `> max_message_size`. |
| **Enforce Rate Limit** | Track requests per connection in a 60-second sliding window; return `rate-limited` on excess. |
| **Enforce History Bound** | Evict oldest history entry when `session.history` reaches `max_history_entries`. |
| **Record Audit** | Append `AuditLogEntry` to the in-memory log; optionally write to file. |
| **Rotate Audit File** | Rename current audit file to `.1` when it exceeds `rotate_bytes`; open fresh file. |
| **Evict Oldest Audit** | When in-memory log reaches `max_entries`, delete the oldest `evict_count` entries. |
| **Validate ID Length** | Reject requests where `length(id) > max_id_length` (default: 256 bytes). |
| **Umask Socket** | Wrap `listen()` with `umask(0o077)` to ensure the socket file is created owner-only from the first moment. |
| **Interrupt on Disconnect** | On client disconnect, kill all eval tasks associated with sessions used by that connection. |

## Error Status Codes (security-related)

| Status Flag | Trigger |
|-------------|---------|
| `session-limit-reached` | `clone` exceeds `max_sessions` |
| `concurrency-limit-reached` | Eval queue is full (`> 2 × max_concurrent_evals`) |
| `rate-limited` | Connection exceeds `rate_limit_per_min` |
| `timeout` | Eval exceeds `max_eval_time_ms` |
| `path-not-allowed` | `load-file` path outside allowlist |
| `unauthorized` | Missing or invalid auth token (post-v1.0) |

## Design Rules

- **Safe Defaults** — all limits are chosen to allow normal interactive use while preventing abuse.
- **Immutable Limits** — `ResourceLimits` is never mutated after startup.
- **Constant-Time Auth** — token comparison uses a constant-time equality function to prevent timing side-channels.
- **Owner-Only Unix Socket** — socket file is `0o600` from creation via umask, not chmod after the fact.
