# Session Context

Scope: execution namespaces, their lifecycle, isolation rules, and the manager
that owns them. The session is the primary user-visible unit of state.

---

## Entities & Value Objects

| Term | Definition |
|------|-----------|
| **Session** | An isolated execution context backed by a Julia `Module`. All code evaluations run inside a session. Two kinds: *ephemeral* and *named (persistent)*. |
| **Ephemeral Session** | Transient. Created automatically when a request omits the `session` field. Destroyed after the request completes. No cross-request state. No identity in `ls-sessions`. |
| **Named Session** (Persistent Session) | Has a UUIDv4 identity, an optional human-readable *alias*, lifecycle state, and history. Survives across requests and connections. |
| **Session ID** | The UUIDv4 string that uniquely identifies a named session. Server-generated. |
| **Session Alias** | Optional human-readable name for a named session. Alphanumeric, hyphens, underscores; max 256 bytes. Resolved to a Session ID on lookup. |
| **Session Module** | The anonymous Julia `Module` that backs each session. Variables and definitions live here; isolated from all other sessions. |
| **Session Manager** | Server-side registry that creates, looks up, and destroys sessions. Enforces the max-sessions cap. |
| **Session State** | Enum tracking lifecycle: `SessionIdle` → `SessionRunning` → `SessionIdle` or `SessionClosed`. |
| **Session History** | Ordered vector of prior eval results kept per session. Bounded at `max_history_entries` (default 1,000). Oldest entry evicted when full. |
| **Eval Lock** | Per-session `Channel{Nothing}(1)` providing FIFO fairness. Ensures only one eval runs at a time within a session. (A `ReentrantLock` does not guarantee order.) |
| **Eval Task** | The Julia `Task` currently executing code in a session. Assigned before execution; cleared on completion. Used as the interrupt target. |
| **Eval Count** | Monotonic integer per session; incremented at eval start. Identifies the current eval for interrupt targeting. |
| **Module Reuse Pool** | Bounded pool of anonymous modules recycled across ephemeral sessions to cap memory growth. Pool size = `max_concurrent_evals`. |

## Operations (verbs)

| Term | Definition |
|------|-----------|
| **Create Session** | Allocate a new named session: generate UUID, optional alias, fresh module, idle state. Rejected if `max_sessions` is reached. |
| **Lookup Session** | Resolve a session by UUID or alias → `NamedSession` (or not-found). |
| **Clone Session** | Create a new session, optionally copying bindings from a parent. *Binding copy*: all names exported from the parent module's global scope are re-bound in the child module at clone time (shallow copy of values; Julia closures capture by reference, so mutable state is shared). Type definitions and method tables are **not** copied — they remain in the parent module and the child refers to them. The clone is a point-in-time snapshot; subsequent mutations to the parent do not propagate. Blocked if `max_sessions` is reached; returns `session-already-exists` if the alias is taken. |
| **Close Session** | Remove a named session from the registry and transition it to `SessionClosed`. Idempotent. |
| **Transition State** | Atomic state-machine step protected by a lock. No partial state is ever externally visible. |
| **Idle Sweep** | Background task that auto-closes sessions whose last-activity timestamp is older than `session_idle_timeout_s`. **Safety rule**: the sweep MUST skip any session in `SessionRunning` state — it never forcibly closes a session with an active eval. The sweep retries on the next interval for those sessions. |
| **Update Last Activity** | Record the timestamp of the most recent operation against a session. |
| **Orphan Cleanup** | On client disconnect: interrupt all in-flight evals for sessions that were used by that connection. **Ephemeral guarantee**: regardless of how the connection ends (clean close, crash, or timeout), the ephemeral session's module is returned to the Module Reuse Pool. This is the sole cleanup path for ephemeral sessions — there is no registry entry to remove. |

## Session Lifecycle (state machine)

```
              clone / create
                    │
              ┌─────▼──────┐
              │ SessionIdle │◄──────────────────────┐
              └─────┬───────┘                       │
                    │ eval starts                   │ eval completes
              ┌─────▼────────┐                      │
              │SessionRunning│──────────────────────┘
              └─────┬────────┘
                    │ close / idle-sweep
              ┌─────▼────────┐
              │SessionClosed │
              └──────────────┘
```

## Isolation Rules

- **No cross-session visibility** — sessions share no bindings; each has its own module namespace.
- **FIFO Eval Serialization** — within one session, evaluations execute in arrival order, one at a time.
- **Ephemeral never appears in `ls-sessions`** — only named sessions are listed.
- **Ephemeral vs. named clone** — cloning copies bindings only when both parent and child are the same kind (light-to-light).

## Edge Cases & Race Conditions

| Scenario | Required behaviour |
|----------|--------------------|
| **Late interrupt** — `interrupt` arrives after the eval has already completed and the session is back to `SessionIdle` | Server responds with `status: ["done"]` (success) and a note field `"interrupt": "noop"`. The interrupt is silently consumed; the client's original eval response stands. |
| **Idle-sweep vs. running eval** — the sweep ticks while a session is in `SessionRunning` | Sweep skips the session this cycle; logs a debug trace. Session is re-evaluated on the next sweep tick after it returns to `SessionIdle`. |
| **Connection drop during eval** | Transport layer triggers Orphan Cleanup: interrupts the eval task, returns ephemeral module to the pool (if applicable), removes the connection's session tracking entries. |
| **Middleware crash during ephemeral eval** | The connection handler wraps all middleware dispatch in a `try/catch`. On uncaught exception, Orphan Cleanup is still called (finally block), ensuring no module leak. |
| **Clone of a running session** | Clone captures the parent module's bindings at request time. If the parent is `SessionRunning`, the snapshot is taken of whatever state existed at the instant the lock was acquired — no guarantee of consistency with in-flight eval results. |

## Limits

| Limit | Default | Enforcement point |
|-------|---------|------------------|
| `max_sessions` | 100 | `clone` / create |
| `max_history_entries` | 1,000 | eval completion |
| `session_idle_timeout_s` | 3,600 | idle sweep |
