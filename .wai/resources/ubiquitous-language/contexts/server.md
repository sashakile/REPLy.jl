# Server Context

Scope: the top-level server object, its lifecycle, and how it coordinates
listeners, connections, and graceful shutdown. Also covers the optional
Revise.jl hot-reload hook.

---

## Entities & Value Objects

| Term | Definition |
|------|-----------|
| **REPLy Server** | The main server entry point. Owns listeners, the session manager, shared state, and the middleware stack. |
| **Server Port** | The TCP port the server is bound to. Default: 5555. Queryable after `serve()` to support OS-assigned ports (`port: 0`). |
| **Socket Path** | File-system path for the Unix domain socket listener. Optional. Removed at startup if a stale file exists. |
| **Server State** | Shared mutable state: `ResourceLimits` (immutable), active eval counter, active eval task set. |
| **Protocol Name** | The constant string `"REPLy"`. Returned in `describe` responses. |
| **Version String** | The package version string. Also reports the Julia `VERSION` in `describe`. |
| **Multi-Listener Server** | A server with both TCP and Unix socket listeners active simultaneously. |
| **Active Eval Registration** | The set of in-flight eval tasks tracked by the server. Used to interrupt all evals during shutdown. |
| **Grace Period** | Configurable delay (default: 5 s) between "stop accepting connections" and "force-close all connections" during shutdown. |
| **Pre-Eval Hook** | A callback invoked before each named-session eval. The Revise hook is the standard example. |
| **Revise Hook** | A pre-eval hook that calls `Revise.revise()` to hot-reload modified source files. Only active if Revise.jl is loaded. |

## Operations (verbs)

| Term | Definition |
|------|-----------|
| **Serve** | Start all configured listeners; begin accepting connections. Blocks until shutdown is requested. |
| **Accept Connection** | Pick up a new OS connection; allocate a `Client Connection`; spawn a `Connection Handler` task. |
| **Shutdown** | Graceful termination (see sequence below). |
| **Register Active Eval** | Add an eval task to the server's active set at eval start. |
| **Unregister Active Eval** | Remove the eval task from the active set on completion or interrupt. |
| **Get Server Port** | Return the bound TCP port (useful when `port: 0` was requested). |
| **Get Socket Path** | Return the Unix socket file path. |
| **Call Pre-Eval Hooks** | Execute all registered pre-eval hooks before each named-session eval. |

## Shutdown Sequence

```
1. Stop accepting new connections
2. Interrupt all registered active eval tasks
3. Wait up to grace_period_s for in-flight work to finish
4. Close all open client connections
5. Clean up listener sockets (remove Unix socket file)
```

## Design Rules

- **Shutdown is ordered** — each phase completes before the next begins.
- **Grace period is configurable** — allows long-running evals to finish cleanly before forced closure.
- **Stale socket removal** — if a Unix socket file already exists at startup, it is removed before binding. This handles crash-recovery without manual cleanup.
- **Revise graceful degradation** — if Revise.jl is not loaded, the hook is a no-op; the server does not crash or warn on every eval.
