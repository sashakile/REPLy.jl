# How-to: Manage Persistent Sessions

By default, REPLy evaluates every `eval` request in a fresh, ephemeral session. If you want to maintain state across multiple requests (e.g., for an editor integration where variables persist between executions), you must use **Named Sessions**.

## 1. Create the Initial Named Session (Server-Side)

Currently, creating a completely new named session must be done from Julia when instantiating the server.

```julia
using REPLy
using REPLy: SessionManager, create_named_session!

# 1. Create a session manager
manager = SessionManager()

# 2. Register a persistent session named "main"
create_named_session!(manager, "main")

# 3. Start the server using this manager
server = serve(manager=manager, port=5555)
wait(Condition())
```

Once the server is running with the configured manager, you can connect over the socket to begin evaluating code in that named session.

## 2. Target a Session via RPC

Once the session exists, clients can evaluate code in it by adding the `"session"` key to their requests:

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
{"id":"ls-1","sessions":[{"name":"main","created-at":1713500000.0}]}
{"id":"ls-1","status":["done"]}
```

## 4. Clone a Session

Instead of creating new sessions from the server side, clients can clone an existing session. This creates a new anonymous module that copies all bindings from the source session, ensuring mutations in the clone do not affect the original.

```json
{"op": "clone-session", "id": "clone-1", "source": "main", "name": "experiment"}
```

If successful, the new session `"experiment"` is ready for use:

```json
{"id": "clone-1", "name": "experiment"}
{"id": "clone-1", "status": ["done"]}
```

## 5. Close a Session

When a session is no longer needed, close it to free resources:

```json
{"op": "close-session", "id": "close-1", "name": "experiment"}
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
