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

    @testset "interrupt running eval includes interrupted-id in response" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "int-id-session")
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
        @async begin
            eval_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
            msgs = REPLy.dispatch_middleware(eval_stack, 1, Dict(
                "op" => "eval",
                "id" => "eval-int-id",
                "session" => "int-id-session",
                "code" => "sleep(10)",
            ), eval_ctx)
            put!(eval_done, msgs)
        end

        timeout = time() + 5.0
        while REPLy.session_state(REPLy.lookup_named_session(manager, "int-id-session")) !== REPLy.SessionRunning
            yield()
            time() > timeout && error("timed out waiting for eval to start")
        end

        int_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        int_msgs = REPLy.dispatch_middleware(interrupt_stack, 1,
            Dict("op" => "interrupt", "id" => "i-int-id", "session" => "int-id-session"), int_ctx)

        @test haskey(int_msgs[1], "interrupted-id")
        @test int_msgs[1]["interrupted-id"] isa Integer
        @test int_msgs[1]["interrupted-id"] == 1

        timedwait(() -> isready(eval_done), 5.0)
    end

    @testset "interrupt idle session returns interrupted-id == nothing" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "int-id-idle")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.InterruptMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "interrupt", "id" => "i-idle-id", "session" => "int-id-idle"), ctx)

        @test haskey(msgs[1], "interrupted-id")
        @test isnothing(msgs[1]["interrupted-id"])
    end

    @testset "interrupt-id matches running eval — interrupts and returns interrupted-id" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "int-id-match")

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
        @async begin
            eval_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
            msgs = REPLy.dispatch_middleware(eval_stack, 1, Dict(
                "op" => "eval",
                "id" => "eval-match",
                "session" => "int-id-match",
                "code" => "sleep(10)",
            ), eval_ctx)
            put!(eval_done, msgs)
        end

        timeout = time() + 5.0
        while REPLy.session_state(REPLy.lookup_named_session(manager, "int-id-match")) !== REPLy.SessionRunning
            yield()
            time() > timeout && error("timed out waiting for eval to start")
        end

        # interrupt-id == 1 matches the running eval
        int_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        int_msgs = REPLy.dispatch_middleware(interrupt_stack, 1,
            Dict("op" => "interrupt", "id" => "i-match", "session" => "int-id-match",
                 "interrupt-id" => 1), int_ctx)

        @test int_msgs[1]["interrupted"] == ["int-id-match"]
        @test int_msgs[1]["interrupted-id"] == 1

        timedwait(() -> isready(eval_done), 5.0)
    end

    @testset "interrupt-id does not match running eval — no-op success" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "int-id-mismatch")

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
        @async begin
            eval_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
            msgs = REPLy.dispatch_middleware(eval_stack, 1, Dict(
                "op" => "eval",
                "id" => "eval-mismatch",
                "session" => "int-id-mismatch",
                "code" => "sleep(10)",
            ), eval_ctx)
            put!(eval_done, msgs)
        end

        timeout = time() + 5.0
        while REPLy.session_state(REPLy.lookup_named_session(manager, "int-id-mismatch")) !== REPLy.SessionRunning
            yield()
            time() > timeout && error("timed out waiting for eval to start")
        end

        # interrupt-id == 99 does not match the running eval (which has id 1)
        int_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        int_msgs = REPLy.dispatch_middleware(interrupt_stack, 1,
            Dict("op" => "interrupt", "id" => "i-mismatch", "session" => "int-id-mismatch",
                 "interrupt-id" => 99), int_ctx)

        @test int_msgs[1]["interrupted"] == []
        @test isnothing(int_msgs[1]["interrupted-id"])

        # Eval should still be running (not interrupted)
        session = REPLy.lookup_named_session(manager, "int-id-mismatch")
        @test REPLy.session_state(session) === REPLy.SessionRunning

        # Clean up: interrupt without id
        REPLy.dispatch_middleware(interrupt_stack, 1,
            Dict("op" => "interrupt", "id" => "i-cleanup", "session" => "int-id-mismatch"), int_ctx)
        timedwait(() -> isready(eval_done), 5.0)
    end

    @testset "uses ctx.session when already resolved — no TOCTOU re-lookup (wep)" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "wep-interrupt-sess")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        ctx.session = session  # simulate what SessionMiddleware would have set

        # Destroy from the registry — simulates the TOCTOU window where destroy
        # races between SessionMiddleware resolution and the downstream lookup.
        REPLy.destroy_named_session!(manager, "wep-interrupt-sess")

        stack = REPLy.AbstractMiddleware[REPLy.InterruptMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "interrupt", "id" => "i-wep", "session" => "wep-interrupt-sess"), ctx)

        # Session is closed (after destroy), so no eval running — interrupted=[] is correct.
        # Before fix: re-lookup returns nothing → session-not-found error (wrong).
        # After fix: uses ctx.session → idle path → interrupted=[].
        @test length(msgs) == 2
        @test msgs[1]["interrupted"] == []
        @test msgs[2]["status"] == ["done"]
    end
end
