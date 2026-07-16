"""
    ServerState

Shared mutable state that lives at the server level (above any individual connection).
Holds the configured `ResourceLimits` and runtime counters that span all client sessions.

- `limits::ResourceLimits` — resource limits configured at `serve()` time.
- `max_message_bytes::Int` — maximum inbound message size (bytes).
- `active_evals::Threads.Atomic{Int}` — number of eval operations currently in flight server-wide.
- `eval_queue::Vector{Task}` — FIFO queue of waiting eval tasks (each entry is the blocked task).
- `eval_queue_cond::Threads.Condition` — condition variable with embedded lock, signaled when an eval finishes and a slot opens.
"""
mutable struct SessionSweeper
    timer::Timer
    task::Task
end

mutable struct ServerState
    limits::ResourceLimits
    max_message_bytes::Int
    active_evals::Threads.Atomic{Int}
    active_eval_lock::ReentrantLock
    active_eval_tasks::IdDict{Task, Nothing}
    session_sweeper::Union{Nothing, SessionSweeper}
    eval_queue::Vector{Task}
    eval_queue_cond::Threads.Condition
end

"""
    ServerState(limits, max_message_bytes) -> ServerState

Construct a `ServerState` with all counters initialised to zero.
"""
ServerState(limits::ResourceLimits, max_message_bytes::Int) =
    ServerState(limits, max_message_bytes, Threads.Atomic{Int}(0), ReentrantLock(), IdDict{Task, Nothing}(), nothing, Vector{Task}(), Threads.Condition())

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

"""
    _eval_acquire_slot(state) -> Bool

Acquire a concurrent eval slot, or queue FIFO up to 2× limit, or reject.
Blocks the calling task when queued until a slot opens. Returns `true` when
a slot is acquired, `false` when the queue is full and the eval is rejected.
"""
function _eval_acquire_slot(state::ServerState)
    limit = state.limits.max_concurrent_evals
    while true
        current = Threads.atomic_add!(state.active_evals, 1)
        if current < limit
            return true  # slot acquired
        end
        # At cap: undo increment, try to queue
        Threads.atomic_sub!(state.active_evals, 1)
        rejected = lock(state.eval_queue_cond) do
            if length(state.eval_queue) >= limit * 2
                true
            else
                push!(state.eval_queue, current_task())
                false
            end
        end
        if rejected
            return false  # queue full
        end
        # Wait for a slot to open (blocking). The notifier pops the front of the
        # queue, so FIFO order is maintained by the queue's insertion order.
        lock(state.eval_queue_cond) do
            wait(state.eval_queue_cond)  # releases lock, blocks, re-acquires on notify
        end
        # Slot should now be available — loop back to acquire it
    end
end

"""
    _eval_release_slot(state)

Release a concurrent eval slot and notify the next queued eval (if any).
Must be called from the finally block of an eval (after decrementing active_evals).
"""
function _eval_release_slot(state::ServerState)
    lock(state.eval_queue_cond) do
        if !isempty(state.eval_queue)
            popfirst!(state.eval_queue)
            notify(state.eval_queue_cond)
        end
    end
    return nothing
end
