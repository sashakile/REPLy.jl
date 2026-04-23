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
    active_eval_lock::ReentrantLock
    active_eval_tasks::IdDict{Task, Nothing}
end

"""
    ServerState(limits, max_message_bytes) -> ServerState

Construct a `ServerState` with all counters initialised to zero.
"""
ServerState(limits::ResourceLimits, max_message_bytes::Int) =
    ServerState(limits, max_message_bytes, Threads.Atomic{Int}(0), ReentrantLock(), IdDict{Task, Nothing}())

function register_active_eval!(state::ServerState, task::Task)
    lock(state.active_eval_lock) do
        state.active_eval_tasks[task] = nothing
    end
    return task
end

function unregister_active_eval!(state::ServerState, task::Task)
    lock(state.active_eval_lock) do
        delete!(state.active_eval_tasks, task)
    end
    return nothing
end

active_eval_tasks(state::ServerState) = lock(state.active_eval_lock) do
    collect(keys(state.active_eval_tasks))
end
