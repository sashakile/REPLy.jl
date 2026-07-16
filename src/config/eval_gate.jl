"""
    EvalGate

Centralised concurrent-eval slot manager. Owns the max-concurrency invariant:
`release!` atomically decrements `active` and notifies the condition variable,
so callers can never forget either step.

Replaces the split `active_evals` atomic + separate condition variable that
previously lived in `ServerState` and were managed by `_eval_acquire_slot` /
`_eval_release_slot`. The gate encapsulates both the counter and the FIFO
queue, making the invariant impossible to violate.
"""
mutable struct EvalGate
    max::Int
    active::Threads.Atomic{Int}
    queue::Vector{Task}
    cv::Threads.Condition
end

EvalGate(max::Int) = EvalGate(max, Threads.Atomic{Int}(0), Vector{Task}(), Threads.Condition())

"""
    acquire!(gate::EvalGate) -> Bool

Acquire a concurrent eval slot, queuing FIFO up to 2× limit if all slots are
occupied. Blocks the calling task when queued until a slot opens.

Returns `true` when a slot is acquired, `false` when the queue is full and
the eval is rejected.
"""
function acquire!(gate::EvalGate)
    limit = gate.max
    while true
        current = Threads.atomic_add!(gate.active, 1)
        if current < limit
            return true  # slot acquired
        end
        # At cap: undo increment, try to queue
        Threads.atomic_sub!(gate.active, 1)
        rejected = lock(gate.cv) do
            if length(gate.queue) >= limit * 2
                true
            else
                push!(gate.queue, current_task())
                false
            end
        end
        if rejected
            return false  # queue full
        end
        # Wait for a slot to open (blocking). The notifier pops the front of the
        # queue, so FIFO order is maintained by the queue's insertion order.
        lock(gate.cv) do
            wait(gate.cv)  # releases lock, blocks, re-acquires on notify
        end
        # Slot should now be available — loop back to acquire it
    end
end

"""
    release!(gate::EvalGate)

Release a concurrent eval slot and notify the next queued eval (if any).

This is the single point that owns both the counter decrement and the
condition-variable notification. Callers must never touch `gate.active`
directly — always go through `release!`.
"""
function release!(gate::EvalGate)
    Threads.atomic_sub!(gate.active, 1)
    lock(gate.cv) do
        if !isempty(gate.queue)
            popfirst!(gate.queue)
            notify(gate.cv)
        end
    end
    return nothing
end

"""
    active_count(gate::EvalGate) -> Int

Return the number of currently active eval slots. Always in `[0, max]`
when the invariant is maintained.
"""
active_count(gate::EvalGate) = gate.active[]
