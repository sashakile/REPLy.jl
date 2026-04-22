@testset "eval option compliance" begin
    function make_ctx(manager=REPLy.SessionManager())
        REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
    end

    function eval_stack()
        REPLy.AbstractMiddleware[
            REPLy.SessionMiddleware(),
            REPLy.EvalMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ]
    end

    # ── module routing ────────────────────────────────────────────────────────

    @testset "module field routes eval into specified submodule" begin
        # Use Base.Iterators which is a real submodule of Main (via Base).
        # This tests dotted-path resolution without global side effects.
        manager = REPLy.SessionManager()
        ctx = make_ctx(manager)

        msgs = REPLy.dispatch_middleware(
            REPLy.AbstractMiddleware[REPLy.EvalMiddleware(), REPLy.UnknownOpMiddleware()],
            1,
            Dict("op" => "eval", "id" => "m1",
                 "module" => "Base.Iterators", "code" => "zip isa Function"),
            ctx)

        value_msg = only(filter(m -> haskey(m, "value"), msgs))
        @test value_msg["value"] == "true"
    end

    @testset "unresolvable module returns error" begin
        manager = REPLy.SessionManager()
        ctx = make_ctx(manager)

        msgs = REPLy.dispatch_middleware(
            REPLy.AbstractMiddleware[REPLy.EvalMiddleware(), REPLy.UnknownOpMiddleware()],
            1,
            Dict("op" => "eval", "id" => "m2",
                 "module" => "Main.DoesNotExist", "code" => "1+1"),
            ctx)

        status_msg = only(filter(m -> haskey(m, "status"), msgs))
        @test "error" in status_msg["status"]
        @test occursin("Cannot resolve module", status_msg["err"])
    end

    # ── allow-stdin ───────────────────────────────────────────────────────────

    @testset "allow-stdin false causes EOFError on byte read" begin
        # Note: readline() catches EOFError internally and returns ""; use
        # read(stdin, UInt8) to observe the EOFError that devnull stdin raises.
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "no-stdin-sess")
        ctx = make_ctx(manager)
        stack = eval_stack()

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "as1", "session" => "no-stdin-sess",
                 "allow-stdin" => false, "code" => "read(stdin, UInt8)"), ctx)

        status_msg = only(filter(m -> haskey(m, "status"), msgs))
        @test "error" in status_msg["status"]
        @test occursin("EOFError", status_msg["err"])
    end

    @testset "allow-stdin true (default) allows readline to block" begin
        # When allow-stdin is true, readline should block waiting for input.
        # We verify by providing input via StdinMiddleware.
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "yes-stdin-sess")

        stack = eval_stack()
        stdin_stack = REPLy.AbstractMiddleware[REPLy.StdinMiddleware(), REPLy.UnknownOpMiddleware()]

        eval_done = Channel{Vector{Dict{String, Any}}}(1)
        @async begin
            msgs = REPLy.dispatch_middleware(stack, 1,
                Dict("op" => "eval", "id" => "as2", "session" => "yes-stdin-sess",
                     "allow-stdin" => true, "code" => "readline()"), make_ctx(manager))
            put!(eval_done, msgs)
        end

        timeout = time() + 5.0
        while REPLy.session_state(REPLy.lookup_named_session(manager, "yes-stdin-sess")) !== REPLy.SessionRunning
            yield()
            time() > timeout && error("timed out")
        end

        REPLy.dispatch_middleware(stdin_stack, 1,
            Dict("op" => "stdin", "id" => "si2", "session" => "yes-stdin-sess", "input" => "ok\n"),
            make_ctx(manager))

        eval_msgs = timedwait(() -> isready(eval_done), 5.0) === :ok ? take!(eval_done) : nothing
        @test !isnothing(eval_msgs)
        value_msg = only(filter(m -> haskey(m, "value"), eval_msgs))
        @test value_msg["value"] == "\"ok\""
    end

    # ── timeout-ms validation ─────────────────────────────────────────────────

    @testset "timeout-ms below 1 rejected" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "tm-sess")
        ctx = make_ctx(manager)
        stack = eval_stack()

        for bad_val in [0, -1, -100]
            msgs = REPLy.dispatch_middleware(stack, 1,
                Dict("op" => "eval", "id" => "tm1", "session" => "tm-sess",
                     "timeout-ms" => bad_val, "code" => "1"), ctx)
            status_msg = only(filter(m -> haskey(m, "status"), msgs))
            @test "error" in status_msg["status"]
            @test occursin("timeout-ms", status_msg["err"])
        end
    end

    @testset "timeout-ms >= 1 accepted" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "tm-ok-sess")
        ctx = make_ctx(manager)
        stack = eval_stack()

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "tm2", "session" => "tm-ok-sess",
                 "timeout-ms" => 5000, "code" => "1+1"), ctx)
        value_msg = only(filter(m -> haskey(m, "value"), msgs))
        @test value_msg["value"] == "2"
    end

    @testset "timeout-ms non-integer (string) rejected" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "tm-bad-sess")
        ctx = make_ctx(manager)
        stack = eval_stack()

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "tm3", "session" => "tm-bad-sess",
                 "timeout-ms" => "fast", "code" => "1"), ctx)
        status_msg = only(filter(m -> haskey(m, "status"), msgs))
        @test "error" in status_msg["status"]
    end

    @testset "timeout-ms float rejected" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "tm-float-sess")
        ctx = make_ctx(manager)
        stack = eval_stack()

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "tm4", "session" => "tm-float-sess",
                 "timeout-ms" => 1.5, "code" => "1"), ctx)
        status_msg = only(filter(m -> haskey(m, "status"), msgs))
        @test "error" in status_msg["status"]
        @test occursin("timeout-ms", status_msg["err"])
    end

    # ── silent mode ───────────────────────────────────────────────────────────

    @testset "silent suppresses value message" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "silent-sess")
        ctx = make_ctx(manager)
        stack = eval_stack()

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "sl1", "session" => "silent-sess",
                 "silent" => true, "code" => "42"), ctx)

        @test !any(m -> haskey(m, "value"), msgs)
        @test any(m -> haskey(m, "status") && "done" in m["status"], msgs)
    end

    @testset "silent still emits out and err" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "silent-out-sess")
        ctx = make_ctx(manager)
        stack = eval_stack()

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "sl2", "session" => "silent-out-sess",
                 "silent" => true, "code" => "println(\"hi\")"), ctx)

        @test !any(m -> haskey(m, "value"), msgs)
        @test any(m -> get(m, "out", "") == "hi\n", msgs)
    end

    @testset "silent false (default) emits value" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "not-silent-sess")
        ctx = make_ctx(manager)
        stack = eval_stack()

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "sl3", "session" => "not-silent-sess",
                 "silent" => false, "code" => "99"), ctx)

        @test any(m -> haskey(m, "value"), msgs)
        value_msg = only(filter(m -> haskey(m, "value"), msgs))
        @test value_msg["value"] == "99"
    end
end
