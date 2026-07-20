"""
    EvalGate

Centralised concurrent-eval slot manager. Owns the max-concurrency invariant:
`release!` either decrements `active` or transfers the occupied slot directly to
the first queued waiter, so callers can never forget either step.

Replaces the split `active_evals` atomic + separate condition variable that
previously lived in `ServerState` and were managed by `_eval_acquire_slot` /
`_eval_release_slot`. The gate encapsulates both the counter and the FIFO
queue, making the invariant impossible to violate.
"""
mutable struct EvalGate
    max::Int
    active::Threads.Atomic{Int}
    queue::Vector{Channel{Nothing}}
    lock::ReentrantLock
end

EvalGate(max::Int) = EvalGate(max, Threads.Atomic{Int}(0), Channel{Nothing}[], ReentrantLock())

"""
    acquire!(gate::EvalGate) -> Bool

Acquire a concurrent eval slot, queuing FIFO up to 2× limit if all slots are
occupied. Blocks the calling task when queued until a slot opens.

Returns `true` when a slot is acquired, `false` when the queue is full and
the eval is rejected.
"""
function acquire!(gate::EvalGate)
    limit = gate.max
    waiter = nothing
    acquired = false

    rejected = lock(gate.lock) do
        if gate.active[] < limit
            Threads.atomic_add!(gate.active, 1)
            acquired = true
            return false
        end

        queue_limit = limit > typemax(Int) ÷ 2 ? typemax(Int) : limit * 2
        if length(gate.queue) >= queue_limit
            return true
        end

        waiter = Channel{Nothing}(1)
        push!(gate.queue, waiter)
        return false
    end

    rejected && return false
    acquired && return true

    # A buffered channel retains a handoff even if release! runs before take!,
    # avoiding the lost-notification window of a condition variable.
    take!(waiter::Channel{Nothing})
    return true
end

"""
    release!(gate::EvalGate)

Release a concurrent eval slot or transfer it to the next queued eval.

This is the single point that owns both counter updates and FIFO handoff. Callers
must never touch `gate.active` directly — always go through `release!`.
"""
function release!(gate::EvalGate)
    waiter = lock(gate.lock) do
        if isempty(gate.queue)
            Threads.atomic_sub!(gate.active, 1)
            return nothing
        end

        # Keep active unchanged: the occupied slot is reserved for this waiter.
        return popfirst!(gate.queue)
    end

    isnothing(waiter) || put!(waiter, nothing)
    return nothing
end

"""
    active_count(gate::EvalGate) -> Int

Return the number of currently active eval slots. Always in `[0, max]`
when the invariant is maintained.
"""
active_count(gate::EvalGate) = gate.active[]
