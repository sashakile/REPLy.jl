@testset "stdin middleware" begin
    @testset "missing session field returns error" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.StdinMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "stdin", "id" => "s1", "input" => "hello\n"), ctx)

        @test length(msgs) == 1
        @test "error" in only(msgs)["status"]
        @test occursin("session", only(msgs)["err"])
    end

    @testset "unknown session returns session-not-found error" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.StdinMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "stdin", "id" => "s2", "session" => "nosuch", "input" => "hello\n"), ctx)

        @test length(msgs) == 1
        @test "error" in only(msgs)["status"]
        @test "session-not-found" in only(msgs)["status"]
    end

    @testset "missing input field returns error" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "test-sess")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.StdinMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "stdin", "id" => "s3", "session" => "test-sess"), ctx)

        @test length(msgs) == 1
        @test "error" in only(msgs)["status"]
        @test occursin("input", only(msgs)["err"])
    end

    @testset "buffered input: idle session returns buffered list" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "idle-sess")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.StdinMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "stdin", "id" => "s4", "session" => "idle-sess", "input" => "buffered\n"), ctx)

        @test length(msgs) == 2
        @test msgs[1]["buffered"] == ["idle-sess"]
        @test msgs[2]["status"] == ["done"]
    end

    @testset "buffered input is consumed by subsequent eval" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "buf-eval-sess")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)

        stdin_stack = REPLy.AbstractMiddleware[REPLy.StdinMiddleware(), REPLy.UnknownOpMiddleware()]
        eval_stack  = REPLy.AbstractMiddleware[
            REPLy.SessionMiddleware(),
            REPLy.EvalMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ]

        # Buffer input before eval starts.
        REPLy.dispatch_middleware(stdin_stack, 1,
            Dict("op" => "stdin", "id" => "s5", "session" => "buf-eval-sess", "input" => "buffered line\n"), ctx)

        # Eval reads the buffered line.
        eval_msgs = REPLy.dispatch_middleware(eval_stack, 1,
            Dict("op" => "eval", "id" => "e5", "session" => "buf-eval-sess", "code" => "readline()"), ctx)

        value_msg = only(filter(m -> haskey(m, "value"), eval_msgs))
        @test value_msg["value"] == "\"buffered line\""
    end

    @testset "delivered input: running eval receives stdin and returns delivered list" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "running-sess")

        eval_stack = REPLy.AbstractMiddleware[
            REPLy.SessionMiddleware(),
            REPLy.EvalMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ]
        stdin_stack = REPLy.AbstractMiddleware[
            REPLy.StdinMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ]

        eval_done = Channel{Vector{Dict{String, Any}}}(1)
        @async begin
            eval_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
            msgs = REPLy.dispatch_middleware(eval_stack, 1,
                Dict("op" => "eval", "id" => "e6", "session" => "running-sess",
                     "code" => "readline()"), eval_ctx)
            put!(eval_done, msgs)
        end

        # Wait for session to become SessionRunning.
        timeout = time() + 5.0
        while REPLy.session_state(REPLy.lookup_named_session(manager, "running-sess")) !== REPLy.SessionRunning
            yield()
            time() > timeout && error("timed out waiting for eval to start")
        end

        # Deliver stdin to the blocked eval.
        stdin_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stdin_msgs = REPLy.dispatch_middleware(stdin_stack, 1,
            Dict("op" => "stdin", "id" => "s6", "session" => "running-sess", "input" => "hello world\n"), stdin_ctx)

        @test stdin_msgs[1]["delivered"] == ["running-sess"]
        @test stdin_msgs[2]["status"] == ["done"]

        # Eval should complete with the line.
        eval_msgs = timedwait(() -> isready(eval_done), 5.0) === :ok ? take!(eval_done) : nothing
        @test !isnothing(eval_msgs)
        value_msg = only(filter(m -> haskey(m, "value"), eval_msgs))
        @test value_msg["value"] == "\"hello world\""
    end

    @testset "closed session (state=SessionClosed) returns error" begin
        # Force SessionClosed without removing from dict (defensive test for the closed-check path).
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "closed-sess")
        lock(session.lock) do; session.state = REPLy.SessionClosed; end
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.StdinMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "stdin", "id" => "s8", "session" => "closed-sess", "input" => "hi\n"), ctx)

        @test length(msgs) == 1
        @test "error" in only(msgs)["status"]
    end

    @testset "non-stdin ops are forwarded" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.StdinMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "s7"), ctx)

        @test "unknown-op" in only(msgs)["status"]
    end
end
