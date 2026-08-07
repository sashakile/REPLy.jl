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
struct EvalGateWaiter
    signal::Channel{Bool}
    lifecycle::Union{EvalLifecycle,Nothing}
end

mutable struct EvalGate
    max::Int
    active::Threads.Atomic{Int}
    zombies::Int
    accepting::Bool
    queue::Vector{EvalGateWaiter}
    lock::ReentrantLock
end

EvalGate(max::Int) = EvalGate(max, Threads.Atomic{Int}(0), 0, true, EvalGateWaiter[], ReentrantLock())

"""
    acquire!(gate::EvalGate) -> Bool

Acquire a concurrent eval slot, queuing FIFO up to 2× limit if all slots are
occupied. Blocks the calling task when queued until a slot opens.

Returns `true` when a slot is acquired, `false` when the queue is full and
the eval is rejected.
"""
function acquire!(gate::EvalGate, lifecycle::Union{EvalLifecycle,Nothing}=nothing)
    limit = gate.max
    waiter = nothing
    acquired = false

    rejected = lock(gate.lock) do
        gate.accepting || return true
        gate.zombies >= limit && return true
        if gate.active[] < limit
            Threads.atomic_add!(gate.active, 1)
            acquired = true
            return false
        end

        queue_limit = limit > typemax(Int) ÷ 2 ? typemax(Int) : limit * 2
        if length(gate.queue) >= queue_limit
            return true
        end

        waiter = EvalGateWaiter(Channel{Bool}(1), lifecycle)
        push!(gate.queue, waiter)
        return false
    end

    rejected && return false
    acquired && return true

    queued_waiter = waiter::EvalGateWaiter
    while true
        if isready(queued_waiter.signal)
            handed_off = take!(queued_waiter.signal)
            cancelled = !isnothing(lifecycle) && lock((lifecycle::EvalLifecycle).lock) do
                lifecycle.cancel_requested
            end
            if handed_off && cancelled
                release!(gate)
                return false
            end
            return handed_off
        end
        cancelled = !isnothing(lifecycle) && lock((lifecycle::EvalLifecycle).lock) do
            lifecycle.cancel_requested
        end
        if cancelled
            removed = lock(gate.lock) do
                index = findfirst(==(queued_waiter), gate.queue)
                isnothing(index) ? false : (deleteat!(gate.queue, index); true)
            end
            removed && return false
            # The waiter left the queue before cancellation acquired the gate
            # lock. Consume the retained decision; a won permit is released
            # exactly once so the next FIFO survivor can progress.
            handed_off = take!(queued_waiter.signal)
            handed_off && release!(gate)
            return false
        end
        sleep(0.001)
    end
end

"""Atomically reject future acquisitions and wake every queued waiter."""
function shutdown!(gate::EvalGate)
    waiters = lock(gate.lock) do
        gate.accepting || return EvalGateWaiter[]
        gate.accepting = false
        splice!(gate.queue, eachindex(gate.queue))
    end
    foreach(waiter -> put!(waiter.signal, false), waiters)
    return nothing
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

    isnothing(waiter) || put!(waiter.signal, true)
    return nothing
end

function mark_zombie!(gate::EvalGate)
    waiters = lock(gate.lock) do
        gate.zombies += 1
        gate.zombies >= gate.max ? splice!(gate.queue, eachindex(gate.queue)) : EvalGateWaiter[]
    end
    foreach(waiter -> put!(waiter.signal, false), waiters)
    return nothing
end

function release_zombie!(gate::EvalGate)
    lock(gate.lock) do
        gate.zombies -= 1
    end
    release!(gate)
end

"""
    active_count(gate::EvalGate) -> Int

Return the number of currently active eval slots. Always in `[0, max]`
when the invariant is maintained.
"""
active_count(gate::EvalGate) = gate.active[]
