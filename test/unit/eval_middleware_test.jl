@testset "eval middleware" begin
    @testset "buffered stdout is emitted before value and done" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-stdout",
            "code" => "print(\"hello\"); println(\" world\"); 1 + 1",
        ))

        assert_conformance(msgs, "eval-stdout")
        out_msgs = filter(msg -> haskey(msg, "out"), msgs)
        @test !isempty(out_msgs)
        @test join(getindex.(out_msgs, "out")) == "hello world\n"
        @test only(filter(msg -> haskey(msg, "value"), msgs))["value"] == "2"
    end

    @testset "buffered stderr is emitted without status before value and done" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-stderr",
            "code" => "print(stderr, \"warn\"); 3 + 4",
        ))

        assert_conformance(msgs, "eval-stderr")
        err_msgs = filter(msg -> haskey(msg, "err") && !haskey(msg, "status"), msgs)
        @test !isempty(err_msgs)
        @test join(getindex.(err_msgs, "err")) == "warn"
        @test all(!haskey(msg, "status") for msg in err_msgs)
        @test only(filter(msg -> haskey(msg, "value"), msgs))["value"] == "7"
    end

    @testset "empty code returns repr(nothing) and done only" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-empty",
            "code" => "   ",
        ))

        assert_conformance(msgs, "eval-empty")
        @test length(msgs) == 2
        @test msgs[1]["value"] == "nothing"
        @test msgs[2]["status"] == ["done"]
    end

    @testset "runtime error responses are not mistaken for buffered stderr messages" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-error",
            "code" => "error(\"boom\")",
        ))

        assert_conformance(msgs, "eval-error")
        @test length(msgs) == 1
        @test haskey(msgs[1], "status")
        @test "error" in msgs[1]["status"]
        @test occursin("boom", msgs[1]["err"])
    end

    @testset "multi-expression eval returns last expression like the REPL" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-multi",
            "code" => "x = 1\ny = x + 1\ny",
        ))

        assert_conformance(msgs, "eval-multi")
        value_msg = only(filter(msg -> haskey(msg, "value"), msgs))
        @test value_msg["value"] == "2"
    end

    @testset "broken result show methods fall back instead of crashing" begin
        struct BrokenShow end
        Base.show(io::IO, ::BrokenShow) = error("broken show")
        Base.show(io::IO, ::MIME"text/plain", ::BrokenShow) = error("broken plain show")

        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-broken-repr",
            "code" => "Main.BrokenShow()",
        ))

        assert_conformance(msgs, "eval-broken-repr")
        value_msg = only(filter(msg -> haskey(msg, "value"), msgs))
        @test value_msg["value"] == "<repr failed: BrokenShow>"
    end

    @testset "broken showerror methods fall back instead of crashing" begin
        struct BrokenEvalError <: Exception end
        Base.show(io::IO, ::BrokenEvalError) = error("broken show")

        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-broken-showerror",
            "code" => "throw(Main.BrokenEvalError())",
        ))

        assert_conformance(msgs, "eval-broken-showerror")
        @test length(msgs) == 1
        @test only(msgs)["err"] == "<showerror failed: BrokenEvalError>"
        @test only(msgs)["ex"]["message"] == "<showerror failed: BrokenEvalError>"
    end

    @testset "concurrent evals keep stdout isolated per request" begin
        handler = REPLy.build_handler()

        task1 = @async handler(Dict(
            "op" => "eval",
            "id" => "eval-concurrent-1",
            "code" => "yield(); println(\"task-1\"); \"task-1\"",
        ))

        task2 = @async handler(Dict(
            "op" => "eval",
            "id" => "eval-concurrent-2",
            "code" => "yield(); println(\"task-2\"); \"task-2\"",
        ))

        msgs1 = fetch(task1)
        msgs2 = fetch(task2)

        assert_conformance(msgs1, "eval-concurrent-1")
        assert_conformance(msgs2, "eval-concurrent-2")

        out1 = join(getindex.(filter(msg -> haskey(msg, "out"), msgs1), "out"))
        out2 = join(getindex.(filter(msg -> haskey(msg, "out"), msgs2), "out"))

        @test out1 == "task-1\n"
        @test out2 == "task-2\n"
    end

    @testset "large repr output is truncated with marker" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], REPLy.create_ephemeral_session!(manager))
        request = Dict("op" => "eval", "id" => "trunc-large", "code" => "repeat(\"x\", 10_000)")

        responses = REPLy.handle_message(
            REPLy.EvalMiddleware(; max_repr_bytes=20),
            request,
            _ -> nothing,
            ctx,
        )

        value_msg = only(filter(m -> haskey(m, "value"), responses))
        @test endswith(value_msg["value"], REPLy.OUTPUT_TRUNCATION_MARKER)
        @test ncodeunits(value_msg["value"]) <= 20 + ncodeunits(REPLy.OUTPUT_TRUNCATION_MARKER)
    end

    @testset "small repr output is not truncated" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], REPLy.create_ephemeral_session!(manager))
        request = Dict("op" => "eval", "id" => "trunc-small", "code" => "42")

        responses = REPLy.handle_message(
            REPLy.EvalMiddleware(; max_repr_bytes=1000),
            request,
            _ -> nothing,
            ctx,
        )

        value_msg = only(filter(m -> haskey(m, "value"), responses))
        @test value_msg["value"] == "42"
    end

    @testset "large buffered output completes without deadlock" begin
        handler = REPLy.build_handler()
        task = @async handler(Dict(
            "op" => "eval",
            "id" => "eval-large-output",
            "code" => "print(repeat(\"a\", 200000)); 1",
        ))

        status = timedwait(() -> istaskdone(task), 5.0)
        @test status == :ok

        msgs = fetch(task)
        assert_conformance(msgs, "eval-large-output")
        out_msgs = filter(msg -> haskey(msg, "out"), msgs)
        @test sum(ncodeunits(msg["out"]) for msg in out_msgs) == 200000
        @test only(filter(msg -> haskey(msg, "value"), msgs))["value"] == "1"
    end

    @testset "named session: eval updates last_active_at" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "activity-test")
        mw = REPLy.EvalMiddleware()
        ctx = REPLy.RequestContext(manager, Dict{String,Any}[], session)

        before = REPLy.session_last_active_at(session)
        sleep(0.005)

        REPLy.handle_message(mw, Dict("op" => "eval", "id" => "act1", "code" => "1+1"), _ -> nothing, ctx)

        @test REPLy.session_state(session) === REPLy.SessionIdle
        @test REPLy.session_eval_task(session) === nothing
        @test REPLy.session_last_active_at(session) > before
    end

    @testset "named session: eval_lock is held during eval and released after" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lock-hold-test")
        mw = REPLy.EvalMiddleware()

        eval_started = Channel{Nothing}(1)
        eval_proceed = Channel{Nothing}(1)
        mod = REPLy.session_module(session)
        Core.eval(mod, :(eval_started = $eval_started))
        Core.eval(mod, :(eval_proceed = $eval_proceed))

        ctx = REPLy.RequestContext(manager, Dict{String,Any}[], session)

        t = @async REPLy.handle_message(
            mw,
            Dict("op" => "eval", "id" => "lock1",
                 "code" => "put!(eval_started, nothing); take!(eval_proceed)"),
            _ -> nothing, ctx,
        )

        take!(eval_started)  # eval is now running inside eval_lock

        held = !trylock(session.eval_lock)
        @test held  # eval_lock is held while eval is running

        put!(eval_proceed, nothing)
        wait(t)

        released = trylock(session.eval_lock)
        @test released  # eval_lock is released after eval completes
        released && unlock(session.eval_lock)
    end

    @testset "cross-session eval_locks are independent" begin
        manager = REPLy.SessionManager()
        s1 = REPLy.create_named_session!(manager, "ind-s1")
        s2 = REPLy.create_named_session!(manager, "ind-s2")

        @test s1.eval_lock !== s2.eval_lock

        lock(s1.eval_lock) do
            got = trylock(s2.eval_lock)
            @test got
            got && unlock(s2.eval_lock)
        end
    end
end

@testset "eval timeout cancellation" begin
    @testset "eval completes before timeout — no timeout status" begin
        limits  = REPLy.ResourceLimits(max_eval_time_ms=5_000)
        manager = REPLy.SessionManager()
        state   = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        handler = REPLy.build_handler(; manager=manager, state=state)

        msgs = handler(Dict("op" => "eval", "id" => "to1", "code" => "1 + 1"))
        terminal = last(msgs)
        @test "done" in terminal["status"]
        @test !("timeout" in terminal["status"])
        @test !("error"   in terminal["status"])
    end

    @testset "eval exceeds timeout-ms — returns timeout status" begin
        handler = REPLy.build_handler()

        msgs = handler(Dict(
            "op"         => "eval",
            "id"         => "to2",
            "code"       => "sleep(600)",
            "timeout-ms" => 300,
        ))
        terminal = last(msgs)
        @test "done"    in terminal["status"]
        @test "error"   in terminal["status"]
        @test "timeout" in terminal["status"]
        @test terminal["err"] == "eval timed out"
    end

    @testset "timeout-ms is capped by server max_eval_time_ms" begin
        # max_eval_time_ms=300 ms means even a large per-request timeout is capped
        limits  = REPLy.ResourceLimits(max_eval_time_ms=300, max_concurrent_evals=10)
        manager = REPLy.SessionManager()
        state   = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        handler = REPLy.build_handler(; manager=manager, state=state)

        msgs = handler(Dict(
            "op"         => "eval",
            "id"         => "to3",
            "code"       => "sleep(600)",
            "timeout-ms" => 60_000,  # large value — should be capped to 300 ms
        ))
        terminal = last(msgs)
        @test "timeout" in terminal["status"]
    end

    @testset "server max_eval_time_ms enforced without per-request timeout-ms" begin
        limits  = REPLy.ResourceLimits(max_eval_time_ms=300, max_concurrent_evals=10)
        manager = REPLy.SessionManager()
        state   = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        handler = REPLy.build_handler(; manager=manager, state=state)

        msgs = handler(Dict("op" => "eval", "id" => "to4", "code" => "sleep(600)"))
        terminal = last(msgs)
        @test "timeout" in terminal["status"]
    end

    @testset "after timeout the session is usable for new evals" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "ts1")
        handler = REPLy.build_handler(; manager=manager)

        # Timeout the named session
        timeout_msgs = handler(Dict(
            "op"         => "eval",
            "id"         => "to5a",
            "code"       => "sleep(600)",
            "session"    => "ts1",
            "timeout-ms" => 300,
        ))
        @test "timeout" in last(timeout_msgs)["status"]

        # Follow-up eval should succeed
        follow_msgs = handler(Dict(
            "op"      => "eval",
            "id"      => "to5b",
            "code"    => "42",
            "session" => "ts1",
        ))
        @test "done" in last(follow_msgs)["status"]
        @test !("timeout" in last(follow_msgs)["status"])
        @test any(get(m, "value", nothing) == "42" for m in follow_msgs)
    end
end

@testset "eval-id in eval response" begin
    @testset "named session eval returns eval-id in done message" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "eval-id-resp")
        mw = REPLy.EvalMiddleware()
        ctx = REPLy.RequestContext(manager, Dict{String,Any}[], session)

        msgs = REPLy.handle_message(mw,
            Dict("op" => "eval", "id" => "eid1", "code" => "1+1"),
            _ -> nothing, ctx)

        done_msg = only(filter(m -> haskey(m, "status") && "done" in m["status"], msgs))
        @test haskey(done_msg, "eval-id")
        @test done_msg["eval-id"] isa Integer
        @test done_msg["eval-id"] == 1
    end

    @testset "successive evals return incrementing eval-id" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "eval-id-incr-resp")
        mw = REPLy.EvalMiddleware()
        ctx = REPLy.RequestContext(manager, Dict{String,Any}[], session)

        msgs1 = REPLy.handle_message(mw,
            Dict("op" => "eval", "id" => "eid2a", "code" => "1"),
            _ -> nothing, ctx)
        msgs2 = REPLy.handle_message(mw,
            Dict("op" => "eval", "id" => "eid2b", "code" => "2"),
            _ -> nothing, ctx)

        done1 = only(filter(m -> haskey(m, "status") && "done" in m["status"], msgs1))
        done2 = only(filter(m -> haskey(m, "status") && "done" in m["status"], msgs2))

        @test done1["eval-id"] == 1
        @test done2["eval-id"] == 2
    end

    @testset "interrupted eval includes eval-id in terminal message" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "eval-id-interrupted")
        ctx = REPLy.RequestContext(manager, Dict{String,Any}[], session)

        eval_stack = REPLy.AbstractMiddleware[
            REPLy.SessionMiddleware(),
            REPLy.EvalMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ]
        interrupt_stack = REPLy.AbstractMiddleware[
            REPLy.InterruptMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ]

        eval_done = Channel{Vector{Dict{String, Any}}}(1)
        eval_task = @async begin
            eval_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
            msgs = REPLy.dispatch_middleware(eval_stack, 1, Dict(
                "op" => "eval",
                "id" => "eval-id-int-eval",
                "session" => "eval-id-interrupted",
                "code" => "sleep(10)",
            ), eval_ctx)
            put!(eval_done, msgs)
        end

        timeout = time() + 5.0
        while REPLy.session_state(session) !== REPLy.SessionRunning
            yield()
            time() > timeout && error("timed out waiting for eval to start")
        end

        int_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        REPLy.dispatch_middleware(interrupt_stack, 1,
            Dict("op" => "interrupt", "id" => "iid-int", "session" => "eval-id-interrupted"), int_ctx)

        eval_msgs = timedwait(() -> isready(eval_done), 5.0) === :ok ? take!(eval_done) : nothing
        @test !isnothing(eval_msgs)
        terminal = only(filter(m -> haskey(m, "status"), eval_msgs))
        @test "interrupted" in terminal["status"]
        @test haskey(terminal, "eval-id")
        @test terminal["eval-id"] isa Integer
    end

    @testset "ephemeral session eval does not include eval-id" begin
        handler = REPLy.build_handler()
        msgs = handler(Dict("op" => "eval", "id" => "eid-eph", "code" => "42"))

        done_msg = only(filter(m -> haskey(m, "status") && "done" in m["status"], msgs))
        @test !haskey(done_msg, "eval-id")
    end
end
