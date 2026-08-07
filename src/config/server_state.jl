"""
    ServerState

Shared mutable state that lives at the server level (above any individual connection).
Holds the configured `ResourceLimits` and runtime counters that span all client sessions.

- `limits::ResourceLimits` — resource limits configured at `serve()` time.
- `max_message_bytes::Int` — maximum inbound message size (bytes).
- `gate::EvalGate` — concurrent-eval slot manager (counter + directed FIFO handoff queue).
"""
mutable struct SessionSweeper
    timer::Timer
    task::Task
end

mutable struct ServerState
    limits::ResourceLimits
    max_message_bytes::Int
    gate::EvalGate
    active_eval_lock::ReentrantLock
    active_eval_tasks::IdDict{Task, EvalLifecycle}
    session_sweeper::Union{Nothing, SessionSweeper}
    shutdown_requested::Ref{Bool}
    active_request_lock::ReentrantLock
    active_request_sockets::IdDict{IO, Int}
    active_request_count::Int
end

"""
    ServerState(limits, max_message_bytes) -> ServerState

Construct a `ServerState` with all counters initialised to zero.
"""
ServerState(limits::ResourceLimits, max_message_bytes::Int) =
    ServerState(limits, max_message_bytes, EvalGate(limits.max_concurrent_evals), ReentrantLock(), IdDict{Task, EvalLifecycle}(), nothing, Ref(false), ReentrantLock(), IdDict{IO, Int}(), 0)

function begin_request!(state::ServerState, socket::IO)
    lock(state.active_request_lock) do
        state.shutdown_requested[] && return false
        state.active_request_count += 1
        state.active_request_sockets[socket] = get(state.active_request_sockets, socket, 0) + 1
        return true
    end
end

function end_request!(state::ServerState, socket::IO)
    lock(state.active_request_lock) do
        state.active_request_count -= 1
        remaining = state.active_request_sockets[socket] - 1
        remaining == 0 ? delete!(state.active_request_sockets, socket) : (state.active_request_sockets[socket] = remaining)
    end
    return nothing
end

active_request_count(state::ServerState) = lock(state.active_request_lock) do
    state.active_request_count
end

request_socket_active(state::ServerState, socket::IO) = lock(state.active_request_lock) do
    haskey(state.active_request_sockets, socket)
end

"""
    effective_limit(state, field, default)

Return the value of `state.limits.<field>` if `state` is a `ServerState`,
or `default` if `state` is `nothing`. Retires the `isnothing(server_state)`
guard pattern that was repeated at every call site.

# Examples
```julia
effective_limit(ctx.server_state, :max_sessions, 100)      # → limit or 100
effective_limit(nothing, :max_output_bytes, typemax(Int))   # → typemax(Int)
```
"""
effective_limit(::Nothing, ::Symbol, default) = default
effective_limit(state::ServerState, field::Symbol, _default) = getfield(state.limits, field)

function register_active_eval!(state::ServerState, task::Task, life::EvalLifecycle)
    return lock(state.active_eval_lock) do
        state.shutdown_requested[] && return false
        state.active_eval_tasks[task] = life
        true
    end
end

function begin_shutdown!(state::ServerState)
    lifecycles = lock(state.active_request_lock) do
        lock(state.active_eval_lock) do
            state.shutdown_requested[] && return EvalLifecycle[]
            # This lock is also the request-admission boundary, so no request
            # can enter after shutdown takes its lifecycle snapshot.
            state.shutdown_requested[] = true
            collect(values(state.active_eval_tasks))
        end
    end
    shutdown!(state.gate)
    return lifecycles
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

active_eval_lifecycles(state::ServerState) = lock(state.active_eval_lock) do
    collect(values(state.active_eval_tasks))
end
