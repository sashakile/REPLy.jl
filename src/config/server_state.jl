"""
    ServerState

Shared mutable state that lives at the server level (above any individual connection).
Holds the configured `ResourceLimits` and runtime counters that span all client sessions.

- `limits::ResourceLimits` — resource limits configured at `serve()` time.
- `max_message_bytes::Int` — maximum inbound message size (bytes).
- `active_evals::Threads.Atomic{Int}` — number of eval operations currently in flight server-wide.
"""
mutable struct ServerState
    limits::ResourceLimits
    max_message_bytes::Int
    active_evals::Threads.Atomic{Int}
end

"""
    ServerState(limits, max_message_bytes) -> ServerState

Construct a `ServerState` with all counters initialised to zero.
"""
ServerState(limits::ResourceLimits, max_message_bytes::Int) =
    ServerState(limits, max_message_bytes, Threads.Atomic{Int}(0))
