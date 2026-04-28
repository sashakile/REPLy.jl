# How-to: Manage Persistent Sessions

By default, REPLy evaluates every `eval` request in a fresh, ephemeral session. If you want to maintain state across multiple requests (e.g., for an editor integration where variables persist between executions), you must use **Named Sessions**.

## 1. Create a Session via RPC

Clients can create a new named session at any time using the `new-session` operation:

```bash
printf '%s\n' '{"op":"new-session","id":"new-1","name":"main"}' | nc 127.0.0.1 5555
```

The server returns the session's UUID and echoes the name alias:

```json
{"id":"new-1","session":"f47ac10b-58cc-4372-a567-0e02b2c3d479","name":"main"}
{"id":"new-1","status":["done"]}
```

The `"session"` UUID is the stable identifier — use it in subsequent requests to route evals to this session. The `"name"` alias is a human-readable shorthand that also works in eval requests.

Omit `"name"` to create an anonymous session (UUID-only):

```json
{"op": "new-session", "id": "new-2"}
```

!!! note "Seeding sessions at server startup"
    If you need well-known sessions to exist before the server accepts connections (e.g., a `"main"` session your editor always connects to), use `create_named_session!` from Julia when constructing the server:

    ```julia
    using REPLy
    using REPLy: SessionManager, create_named_session!

    manager = SessionManager()
    create_named_session!(manager, "main")
    server = serve(manager=manager, port=5555)
    wait(Condition())
    ```

    This is a server-side startup helper, not the primary interface. For all runtime session management, use the RPC ops below.

## 2. Target a Session via RPC

Once a session exists, clients evaluate code in it by adding the `"session"` key to their requests (use the name alias or the UUID interchangeably):

```json
{"op": "eval", "id": "req-1", "session": "main", "code": "x = 42"}
```

Subsequent requests using the same `"session"` string will see the previously defined variables:

```json
{"op": "eval", "id": "req-2", "session": "main", "code": "x + 10"}
```

## 3. List Active Sessions

Clients can discover available sessions using the `ls-sessions` operation. This is useful for editors that need to show a session picker.

```bash
printf '%s\n' '{"op":"ls-sessions","id":"ls-1"}' | nc 127.0.0.1 5555
```

The response will look like:

```json
{"id":"ls-1","sessions":[{"session":"f47ac10b-58cc-4372-a567-0e02b2c3d479","name":"main","created":"2024-04-19T00:00:00","created-at":1713484800.0,"last-activity":"2024-04-19T00:01:00","type":"light","module":"Session_main","eval-count":3,"pid":null}]}
{"id":"ls-1","status":["done"]}
```

Key fields in each session entry:

| Field | Type | Description |
|---|---|---|
| `session` | string | UUID — stable session identifier |
| `name` | string\|null | Name alias, or `null` if anonymous |
| `created` | string | ISO 8601 creation timestamp |
| `created-at` | number | Unix timestamp of creation |
| `last-activity` | string | ISO 8601 timestamp of last eval |
| `type` | string | Session type (`"light"`) |
| `eval-count` | number | Total evals run in this session |

## 4. Clone a Session

Clone an existing session to create a new one that starts with a copy of the source's bindings. Mutations in the clone do not affect the original.

```json
{"op": "clone", "id": "clone-1", "session": "main", "name": "experiment"}
```

Response:

```json
{"id": "clone-1", "new-session": "a1b2c3d4-...", "session": "a1b2c3d4-...", "name": "experiment"}
{"id": "clone-1", "status": ["done"]}
```

The `"new-session"` field carries the UUID of the newly created clone. `"session"` echoes the same value for compatibility. The clone is immediately ready for `eval` requests:

```json
{"op": "eval", "id": "exp-1", "session": "experiment", "code": "x"}
```

## 5. Close a Session

When a session is no longer needed, close it to free resources:

```json
{"op": "close", "id": "close-1", "session": "experiment"}
```

On success, the server returns a bare `done`:

```json
{"id": "close-1", "status": ["done"]}
```

If the session does not exist, you receive a `session-not-found` error:

```json
{"id": "close-1", "status": ["error", "session-not-found"], "err": "Session not found: experiment"}
```

## 6. Session Naming Constraints

Session names must satisfy these rules (enforced at all protocol boundaries):

- Non-empty and non-blank
- Only letters, digits, hyphens (`-`), and underscores (`_`)
- At most `MAX_SESSION_NAME_BYTES` bytes (256)

Names that violate these rules are rejected with a structured error response before reaching the session manager:

```json
{"op": "eval", "id": "req", "session": "my session!", "code": "1+1"}
```

```json
{"id": "req", "status": ["error"], "err": "session name may only contain letters, digits, hyphens, and underscores"}
```

You can validate a name from Julia before sending:

```julia
using REPLy: validate_session_name
err = validate_session_name("my-session")  # returns nothing (valid)
err = validate_session_name("my session!") # returns error string

# Typical usage idiom:
err = validate_session_name(name)
isnothing(err) || error(err)  # or return error_response(..., err)
```

## 7. Inspect Session State

Named sessions expose a lifecycle state machine with three states:

| State | Meaning |
|---|---|
| `SessionIdle` | No eval in progress; ready to accept new requests |
| `SessionRunning` | An eval is in flight |
| `SessionClosed` | Terminal — session has been destroyed |

You can read state from Julia using the thread-safe accessors:

```julia
using REPLy: create_named_session!, SessionManager, session_state, session_eval_task, session_last_active_at
using REPLy: SessionIdle, SessionRunning, SessionClosed

manager = SessionManager()
session = create_named_session!(manager, "main")

session_state(session)           # SessionIdle
session_eval_task(session)       # nothing (idle)
session_last_active_at(session)  # Unix timestamp of most recent activity
```

## 8. Sweep Idle Sessions

In long-running servers, sessions that haven't been used recently can be automatically cleaned up using `sweep_idle_sessions!`:

```julia
using REPLy: SessionManager, create_named_session!, sweep_idle_sessions!

manager = SessionManager()
create_named_session!(manager, "old-session")

sleep(120)  # simulate inactivity

# Destroy any sessions idle for more than 60 seconds
removed = sweep_idle_sessions!(manager; max_idle_seconds=60)
# removed == ["old-session"]
```

This is useful for background cleanup tasks in servers that host many short-lived sessions. Only sessions in `SessionIdle` state are eligible for removal; any session currently in `SessionRunning` is skipped even if it exceeds the idle threshold.

```julia
# Example: periodic sweep in a background task
sweep_task = @async while true
    sleep(300)  # every 5 minutes
    removed = sweep_idle_sessions!(manager; max_idle_seconds=1800)  # 30 min idle
    isempty(removed) || @info "Swept idle sessions" names=removed
end
```

## See Also

- [Protocol Reference](reference-protocol.md) — full request/response contract, all status flags
- [How-to: Use the MCP Adapter](howto-mcp-adapter.md) — MCP lifecycle tools, `mcp_call_tool`, session routing

!!! note "Cleanup on shutdown"
    Store the `@async` return value (as `sweep_task` above) so you can cancel it when the
    server shuts down. Unanchored background tasks are silently abandoned when the process
    exits. Use a `Channel` or `Condition` to signal the task to stop cleanly, e.g.:

    ```julia
    stop = Channel{Nothing}(1)
    sweep_task = @async while !isready(stop)
        sleep(300)
        sweep_idle_sessions!(manager; max_idle_seconds=1800)
    end
    # ... later, on shutdown:
    put!(stop, nothing)
    wait(sweep_task)
    ```
