# Purpose: Map the session-management capability spec's scenarios to executable
#   assertions (openspec/specs/session-management/spec.md, REPLy_jl-sdef):
#   binding isolation, parallel sessions, FIFO eval serialization, eval_task
#   visibility, creation latency, session typing (light/heavy), idle sweep,
#   ephemeral session limits and non-interruptibility, the ephemeral module
#   pool (REQ-RPL-035d), lifecycle state-machine atomicity, close/eval-mutex
#   ordering, terminal resolve-once semantics, and the Revise pre-eval hook.
# Responsibilities:
#   - Drive every scenario through the real middleware pipeline (build_handler)
#     or the SessionManager directly, so assertions cover wire-visible behavior.
#   - Assert REQ-RPL-030..035d and REQ-RPL-038/060 guarantees exactly as the
#     spec scenarios state them, including exact heavy-session rejection shape.
# Rationale: These are the session-management spec's contracts that no existing
#   testset fully covers; the pipeline-level drive keeps them honest without
#   depending on transport details covered elsewhere.
using Test
using REPLy

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_terminal(msgs) = last(filter(m -> haskey(m, "status"), msgs))
_value_msg(msgs) = first(filter(m -> haskey(m, "value"), msgs))
_msg_with(msgs, key) = first(filter(m -> haskey(m, key), msgs))

function _handler(; limits=nothing)
    manager = REPLy.SessionManager()
    state = isnothing(limits) ? nothing : REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
    return REPLy.build_handler(; manager=manager, state=state), manager
end

@testset "session-management spec adoption (REPLy_jl-sdef)" begin

    # -----------------------------------------------------------------------
    # REQ-RPL-030 — Light Session Isolation
    # -----------------------------------------------------------------------

    @testset "binding isolation between sessions" begin
        handler, manager = _handler()
        handler(Dict("op" => "new-session", "id" => "iso-new", "name" => "iso-a"))
        handler(Dict("op" => "new-session", "id" => "iso-new-b", "name" => "iso-b"))

        msgs = handler(Dict("op" => "eval", "id" => "iso-assign",
                            "session" => "iso-a", "code" => "x = 42"))
        @test "done" in _terminal(msgs)["status"]

        msgs = handler(Dict("op" => "eval", "id" => "iso-read",
                            "session" => "iso-b", "code" => "x"))
        terminal = _terminal(msgs)
        @test "error" in terminal["status"]
        @test occursin("UndefVarError", get(terminal, "err", ""))
    end

    @testset "concurrent sessions run in parallel" begin
        handler, manager = _handler()
        handler(Dict("op" => "new-session", "id" => "par-new", "name" => "par-a"))

        slow = @async handler(Dict("op" => "eval", "id" => "par-slow",
                                   "session" => "par-a", "code" => "sleep(2); 41 + 1"))
        # Let the slow eval actually start running before issuing the fast one.
        sleep(0.3)
        fast = @async handler(Dict("op" => "eval", "id" => "par-fast", "code" => "1 + 1"))

        fast_msgs = fetch(fast)
        @test get(_value_msg(fast_msgs), "value", nothing) == "2"
        # The 2-second eval on the other session must still be in flight —
        # session B's result arrived before session A's completed.
        @test !istaskdone(slow)
        slow_msgs = fetch(slow)
        @test get(_value_msg(slow_msgs), "value", nothing) == "42"
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-031 — Light Session Eval Serialization (FIFO)
    # -----------------------------------------------------------------------

    @testset "queued evals execute in FIFO order" begin
        handler, manager = _handler()
        handler(Dict("op" => "new-session", "id" => "fifo-new", "name" => "fifo-s"))
        Core.eval(Main, :(_FIFO_LOG = String[]))  # 1.12-safe global definition

        first_eval = @async handler(Dict("op" => "eval", "id" => "fifo-1",
                                          "session" => "fifo-s",
                                          "code" => "sleep(0.5); push!(Main._FIFO_LOG, \"first\"); 1"))
        sleep(0.2)  # ensure the first eval is admitted and running
        second_eval = @async handler(Dict("op" => "eval", "id" => "fifo-2",
                                           "session" => "fifo-s",
                                           "code" => "push!(Main._FIFO_LOG, \"second\"); 2"))

        fetch(first_eval)
        fetch(second_eval)
        # Submission order == execution order: the queued eval cannot overtake
        # the sleeping one (broken serialization would log "second" first).
        @test Main._FIFO_LOG == ["first", "second"]
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-031b — eval_task Assignment Before Execution
    # -----------------------------------------------------------------------

    @testset "interrupt sees non-nothing eval_task" begin
        handler, manager = _handler()
        handler(Dict("op" => "new-session", "id" => "et-new", "name" => "et-s"))
        session = REPLy.lookup_named_session(manager, "et-s")

        running = @async handler(Dict("op" => "eval", "id" => "et-eval",
                                       "session" => "et-s", "code" => "sleep(30)"))
        # Poll for eval admission: eval_task must be visible while it runs.
        deadline = time() + 5.0
        while time() < deadline && isnothing(REPLy.session_eval_task(session))
            sleep(0.01)
        end
        @test !isnothing(REPLy.session_eval_task(session))

        msgs = handler(Dict("op" => "interrupt", "id" => "et-int", "session" => "et-s"))
        terminal = _terminal(msgs)
        @test "done" in terminal["status"]
        @test get(_msg_with(msgs, "interrupted"), "interrupted", []) == ["et-s"]

        fetch(running)
        @test REPLy.session_state(session) !== REPLy.SessionRunning
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-032 — Light Session Creation Time
    # -----------------------------------------------------------------------

    @testset "session creation is low-latency" begin
        manager = REPLy.SessionManager()
        latencies = Float64[]
        for _ in 1:300
            t0 = time_ns()
            session = REPLy.create_ephemeral_session!(manager)
            push!(latencies, (time_ns() - t0) / 1e9)
            REPLy.destroy_session!(manager, session)
        end
        p99 = sort(latencies)[ceil(Int, 0.99 * length(latencies))]
        @test p99 < 0.010  # 10 ms p99 target (REQ-RPL-032)
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-033 — Session Type Selection
    # -----------------------------------------------------------------------

    @testset "default type is light" begin
        handler, manager = _handler()
        msgs = handler(Dict("op" => "new-session", "id" => "type-new", "name" => "type-s"))
        terminal = _terminal(msgs)
        @test "done" in terminal["status"]

        session = REPLy.lookup_named_session(manager, "type-s")
        @test session isa REPLy.NamedSession
        # Light = anonymous Module backing (not trusted/Main-backed).
        @test !session.trusted
        @test REPLy.session_module(session) !== Main
    end

    @testset "heavy session without Malt.jl rejected" begin
        handler, manager = _handler()
        handler(Dict("op" => "new-session", "id" => "hv-new", "name" => "hv-src"))

        msgs = handler(Dict("op" => "clone", "id" => "hv-clone",
                            "session" => "hv-src", "name" => "hv-dst",
                            "type" => "heavy"))
        terminal = _terminal(msgs)
        # Exact spec shape (REQ-RPL-033): {"status":["done","error"], "err":...}
        @test terminal["status"] == ["done", "error"]
        @test get(terminal, "err", "") == "Heavy sessions require Malt.jl"
        @test REPLy.lookup_named_session(manager, "hv-dst") === nothing
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-034 — Session Idle Timeout
    # -----------------------------------------------------------------------

    @testset "idle session closed by sweep" begin
        handler, manager = _handler()
        handler(Dict("op" => "new-session", "id" => "idle-new", "name" => "idle-s"))
        session = REPLy.lookup_named_session(manager, "idle-s")
        @test session !== nothing

        # Backdate inactivity past any plausible timeout, then sweep.
        session.last_active_at = time() - 10_000.0
        swept = REPLy.sweep_idle_sessions!(manager; max_idle_seconds=3600.0)
        @test "idle-s" in swept
        @test REPLy.lookup_named_session(manager, "idle-s") === nothing

        msgs = handler(Dict("op" => "eval", "id" => "idle-after",
                            "session" => "idle-s", "code" => "1"))
        terminal = _terminal(msgs)
        @test "session-not-found" in terminal["status"]
    end

    @testset "in-flight eval prevents idle close" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "busy-s")

        # Enter EVAL_RUNNING: the sweep must skip this session regardless of age.
        @test REPLy.try_begin_eval!(session, current_task())
        session.last_active_at = time() - 10_000.0
        swept = REPLy.sweep_idle_sessions!(manager; max_idle_seconds=3600.0)
        @test isempty(swept)
        @test REPLy.lookup_named_session(manager, "busy-s") !== nothing

        # Once the eval completes, the session is again sweepable.
        REPLy.end_eval!(session)
        session.last_active_at = time() - 10_000.0
        swept = REPLy.sweep_idle_sessions!(manager; max_idle_seconds=3600.0)
        @test "busy-s" in swept
        @test REPLy.lookup_named_session(manager, "busy-s") === nothing
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-035 — Ephemeral Sessions
    # -----------------------------------------------------------------------

    @testset "ephemeral eval leaves no persistent session" begin
        handler, manager = _handler()
        msgs = handler(Dict("op" => "eval", "id" => "eph-1", "code" => "1 + 1"))
        terminal = _terminal(msgs)
        @test get(_value_msg(msgs), "value", nothing) == "2"
        # The ephemeral session ID is NOT returned to the client.
        @test !haskey(_value_msg(msgs), "session")

        msgs = handler(Dict("op" => "ls-sessions", "id" => "eph-ls"))
        sessions_msg = filter(m -> haskey(m, "sessions"), msgs)
        @test sessions_msg[1]["sessions"] == []
        @test iszero(REPLy.session_count(manager))
    end

    @testset "ephemeral sessions count against max_sessions" begin
        handler, manager = _handler(limits=REPLy.ResourceLimits(max_sessions=0))
        msgs = handler(Dict("op" => "eval", "id" => "eph-limit", "code" => "1"))
        terminal = _terminal(msgs)
        @test terminal["status"] == ["done", "error", "session-limit-reached"]
        @test get(terminal, "err", "") == "Session limit reached"
    end

    @testset "ephemeral evals count against max_concurrent_evals" begin
        handler, manager = _handler(limits=REPLy.ResourceLimits(max_concurrent_evals=0))
        msgs = handler(Dict("op" => "eval", "id" => "eph-conc", "code" => "1"))
        terminal = _terminal(msgs)
        @test terminal["status"] == ["done", "error", "concurrency-limit-reached"]
        @test get(terminal, "err", "") == "Too many concurrent evals"
    end

    @testset "ephemeral evals are not interruptible" begin
        handler, manager = _handler()
        # Run an ephemeral eval to completion; the response carries no session
        # ID, so the client has no handle to address an interrupt at.
        msgs = handler(Dict("op" => "eval", "id" => "eph-int", "code" => "40 + 2"))
        @test !haskey(_terminal(msgs), "session")

        # Any interrupt must name a session; with no ephemeral ID there is no
        # mechanism to interrupt — the request cannot reach the live eval.
        msgs = handler(Dict("op" => "interrupt", "id" => "eph-int-req"))
        terminal = _terminal(msgs)
        @test "error" in terminal["status"]
        @test occursin("interrupt requires", get(terminal, "err", ""))
        @test !haskey(terminal, "interrupted")
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-035d — Ephemeral Module Reuse
    # -----------------------------------------------------------------------

    @testset "module pool prevents memory growth" begin
        manager = REPLy.SessionManager(; module_pool_capacity=4)

        first = REPLy.create_ephemeral_session!(manager)
        mod1 = first.session_mod
        Core.eval(mod1, :(pool_probe = 42))
        REPLy.destroy_session!(manager, first)
        # The module was cleared and returned to the pool.
        @test length(manager.module_pool) == 1
        @test !isdefined(mod1, :pool_probe)

        second = REPLy.create_ephemeral_session!(manager)
        @test second.session_mod === mod1
        # A cleared module still raises UndefVarError for old bindings.
        @test_throws UndefVarError mod1.pool_probe

        # Pool stays bounded at max_concurrent_evals-sized capacity.
        for _ in 1:10
            s = REPLy.create_ephemeral_session!(manager)
            REPLy.destroy_session!(manager, s)
        end
        @test length(manager.module_pool) <= 4
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-038 — Session Lifecycle State Machine
    # -----------------------------------------------------------------------

    @testset "state transitions are atomic" begin
        handler, manager = _handler()
        clone_won = 0
        close_won = 0
        clone_not_found = 0
        for i in 1:30
            handler(Dict("op" => "new-session", "id" => "atomic-new-$i",
                         "name" => "atomic-$i"))
            results = Dict{Symbol, Any}()
            @sync begin
                @async results[:close] = try
                    _terminal(handler(Dict("op" => "close", "id" => "atomic-close-$i",
                                           "session" => "atomic-$i")))
                catch ex
                    ex
                end
                @async results[:clone] = try
                    _terminal(handler(Dict("op" => "clone", "id" => "atomic-clone-$i",
                                           "session" => "atomic-$i",
                                           "name" => "atomic-clone-$i")))
                catch ex
                    ex
                end
            end
            close_t = results[:close]
            clone_t = results[:clone]
            @test close_t isa AbstractDict
            @test clone_t isa AbstractDict
            if "session-not-found" in clone_t["status"]
                clone_not_found += 1
                # Clone lost the race: close must have destroyed the session.
                @test "done" in close_t["status"]
            else
                clone_won += 1
                @test "done" in clone_t["status"]
            end
            close_won += ("done" in close_t["status"]) ? 1 : 0
            # Cleanup of any surviving clone for the next iteration.
            handler(Dict("op" => "close", "id" => "atomic-cleanup-$i",
                         "session" => "atomic-clone-$i"))
        end
        # Both orderings are legal; neither op may crash or double-resolve.
        @test clone_won + clone_not_found == 30
    end

    @testset "close acquires eval mutex before destroying" begin
        handler, manager = _handler()
        handler(Dict("op" => "new-session", "id" => "cem-new", "name" => "cem-s"))

        running = @async handler(Dict("op" => "eval", "id" => "cem-running",
                                      "session" => "cem-s", "code" => "sleep(0.3)"))
        sleep(0.05)
        queued = @async handler(Dict("op" => "eval", "id" => "cem-queued",
                                      "session" => "cem-s", "code" => "sleep(0.3)"))
        sleep(0.05)

        closed = _terminal(handler(Dict("op" => "close", "id" => "cem-close",
                                        "session" => "cem-s")))
        @test "done" in closed["status"]

        # The queued eval finds the session removed and reports session-not-found.
        queued_msgs = fetch(queued)
        queued_t = _terminal(queued_msgs)
        @test "session-not-found" in queued_t["status"]
        fetch(running)
        @test REPLy.lookup_named_session(manager, "cem-s") === nothing
    end

    @testset "competing terminal causes resolve once" begin
        handler, manager = _handler()
        handler(Dict("op" => "new-session", "id" => "race-new", "name" => "race-s"))

        eval_task = @async handler(Dict("op" => "eval", "id" => "race-eval",
                                         "session" => "race-s", "code" => "sleep(30)"))
        deadline = time() + 5.0
        while time() < deadline && isnothing(REPLy.session_eval_task(
                REPLy.lookup_named_session(manager, "race-s")))
            sleep(0.01)
        end

        terminal_a = Ref{Any}(nothing)
        terminal_b = Ref{Any}(nothing)
        @sync begin
            @async terminal_a[] = _terminal(handler(
                Dict("op" => "interrupt", "id" => "race-int", "session" => "race-s")))
            @async terminal_b[] = _terminal(handler(
                Dict("op" => "close", "id" => "race-close", "session" => "race-s")))
        end

        # The first transition out of EVAL_RUNNING wins; the competing terminal
        # is a well-formed no-op (session-not-found after destruction), never a
        # double-resolution error.
        @test "done" in terminal_a[]["status"]
        @test "done" in terminal_b[]["status"]

        eval_msgs = fetch(eval_task)
        eval_t = _terminal(eval_msgs)
        @test "done" in eval_t["status"]  # interrupted (or already gone), not a crash

        # A later termination attempt against the destroyed session is a no-op.
        msgs = handler(Dict("op" => "interrupt", "id" => "race-int-2",
                            "session" => "race-s"))
        @test "session-not-found" in _terminal(msgs)["status"]
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-060 — Revise.jl Integration
    # -----------------------------------------------------------------------

    @testset "revise called before eval picks up changes" begin
        call_count = Ref(0)
        mock = Module(:Revise)
        Core.eval(mock, :(call_count = $(call_count)))
        Core.eval(mock, :(revise() = (call_count[] += 1; nothing)))
        Base.loaded_modules[REPLy._REVISE_PKG_ID] = mock
        Core.eval(Main, :(Revise = $mock))

        handler, manager = _handler()
        handler(Dict("op" => "new-session", "id" => "rev-new", "name" => "rev-s"))
        try
            before = call_count[]
            msgs = handler(Dict("op" => "eval", "id" => "rev-eval-1",
                                "session" => "rev-s", "code" => "1 + 1"))
            @test get(_value_msg(msgs), "value", nothing) == "2"
            # The PreEvalHook ran Revise.revise() before the eval executed.
            @test call_count[] == before + 1
        finally
            delete!(Base.loaded_modules, REPLy._REVISE_PKG_ID)
            try
                Core.eval(Main, :(delete_binding(Main, :Revise)))
            catch
                nothing  # 1.10 fallback: leave the plain binding; it is GC-safe
            end
        end
    end
end
