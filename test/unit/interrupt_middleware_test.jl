@testset "interrupt middleware" begin
    @testset "interrupt idle session returns interrupted=[] (idempotent)" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "idle-session")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.InterruptMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "interrupt", "id" => "i1", "session" => "idle-session"), ctx)

        @test length(msgs) == 2
        @test msgs[1]["interrupted"] == []
        @test msgs[2]["status"] == ["done"]
    end

    @testset "interrupt unknown session returns session-not-found error" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.InterruptMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "interrupt", "id" => "i2", "session" => "nonexistent"), ctx)

        @test length(msgs) == 1
        @test "error" in msgs[1]["status"]
        @test "session-not-found" in msgs[1]["status"]
    end

    @testset "interrupt missing session field returns error" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.InterruptMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "interrupt", "id" => "i3"), ctx)

        @test "error" in only(msgs)["status"]
        @test occursin("session", only(msgs)["err"])
    end

    @testset "interrupt running eval returns interrupted=[session-name] and eval terminates with interrupted status" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "running-session")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)

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
                "id" => "eval-to-interrupt",
                "session" => "running-session",
                "code" => "sleep(10)",
            ), eval_ctx)
            put!(eval_done, msgs)
        end

        # Wait for the eval to start (session transitions to SessionRunning).
        timeout = time() + 5.0
        while REPLy.session_state(REPLy.lookup_named_session(manager, "running-session")) !== REPLy.SessionRunning
            yield()
            time() > timeout && error("timed out waiting for eval to start")
        end

        # Interrupt the running eval.
        int_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        int_msgs = REPLy.dispatch_middleware(interrupt_stack, 1,
            Dict("op" => "interrupt", "id" => "i4", "session" => "running-session"), int_ctx)

        @test int_msgs[1]["interrupted"] == ["running-session"]
        @test int_msgs[2]["status"] == ["done"]

        # Confirm eval task returned with interrupted status.
        eval_msgs = timedwait(() -> isready(eval_done), 5.0) === :ok ? take!(eval_done) : nothing
        @test !isnothing(eval_msgs)
        terminal = only(filter(m -> haskey(m, "status"), eval_msgs))
        @test "interrupted" in terminal["status"]
        @test "done" in terminal["status"]
    end

    @testset "non-interrupt ops are forwarded" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.InterruptMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "eval", "id" => "i5"), ctx)
        @test "unknown-op" in only(msgs)["status"]
    end
end
