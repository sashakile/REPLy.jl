@testset "cap-rejection burst does not degrade server (regression: REPLy_jl-222)" begin
    # Regression: after concurrent evals hit max_concurrent_evals and some are
    # rejected, the server must remain functional — interrupt, stdin, timeout,
    # silent mode, and state tracking must all still work.

    limits   = REPLy.ResourceLimits(max_concurrent_evals=3, max_eval_time_ms=5000)
    manager  = REPLy.SessionManager()
    state    = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
    middleware = REPLy.default_middleware_stack()
    handler    = REPLy.build_handler(; manager=manager, middleware=middleware, state=state)

    handler(Dict("op" => "eval", "id" => "w0", "code" => "1"))  # warmup

    # ── Phase 1: fire >limit concurrent evals ─────────────────────────────
    sessions = ["degrade-s$i" for i in 1:9]
    for name in sessions
        REPLy.create_named_session!(manager, name)
    end

    eval_tasks = map(1:9) do i
        @async handler(Dict(
            "op" => "eval", "id" => "e$i",
            "session" => sessions[i],
            "code" => "sleep(0.3); $i",
        ))
    end
    results = fetch.(eval_tasks)

    rejected = count(results) do msgs
        any(m -> haskey(m, "status") && m["status"] isa Vector &&
                 "concurrency-limit-reached" in m["status"], msgs)
    end
    @test rejected >= 1

    # ── Phase 2: verify no degradation ───────────────────────────────────
    REPLy.create_named_session!(manager, "post-burst")

    # Server state is clean
    @test state.active_evals[] == 0
    @test isempty(REPLy.active_eval_tasks(state))

    # Interrupt works
    int_done = Channel{Bool}(1)
    @async begin
        handler(Dict("op" => "eval", "id" => "int-e",
                     "session" => "post-burst", "code" => "sleep(30)"))
        put!(int_done, true)
    end
    timeout = time() + 5.0
    while REPLy.session_state(REPLy.lookup_named_session(manager, "post-burst")) !== REPLy.SessionRunning
        time() > timeout && error("timed out")
        yield()
    end
    int_resp = handler(Dict("op" => "interrupt", "id" => "int-r",
                            "session" => "post-burst"))
    @test int_resp[1]["interrupted"] == ["post-burst"]
    @test timedwait(() -> isready(int_done), 5.0) === :ok

    # Stdin works
    stdin_ctx = REPLy.RequestContext(manager, Dict{String,Any}[], nothing)
    stdin_stack = REPLy.AbstractMiddleware[REPLy.StdinMiddleware(), REPLy.UnknownOpMiddleware()]
    stdin_msgs = REPLy.dispatch_middleware(stdin_stack, 1,
        Dict("op" => "stdin", "id" => "s1", "session" => "post-burst",
             "input" => "hi\n"), stdin_ctx)
    @test stdin_msgs[1]["buffered"] == ["post-burst"]

    eval_ctx = REPLy.RequestContext(manager, Dict{String,Any}[], nothing)
    eval_stack = REPLy.AbstractMiddleware[
        REPLy.SessionMiddleware(), REPLy.EvalMiddleware(), REPLy.UnknownOpMiddleware()]
    eval_msgs = REPLy.dispatch_middleware(eval_stack, 1,
        Dict("op" => "eval", "id" => "e1", "session" => "post-burst",
             "code" => "readline()"), eval_ctx)
    @test any(m -> get(m, "value", nothing) == "\"hi\"", eval_msgs)

    # Timeout-ms works
    to_ctx = REPLy.RequestContext(manager, Dict{String,Any}[], nothing)
    to_msgs = REPLy.dispatch_middleware(eval_stack, 1,
        Dict("op" => "eval", "id" => "t1", "session" => "post-burst",
             "code" => "sleep(10)", "timeout-ms" => 50), to_ctx)
    @test any(m -> haskey(m, "status") && "timeout" in m["status"], to_msgs)

    # Silent works
    sl_ctx = REPLy.RequestContext(manager, Dict{String,Any}[], nothing)
    sl_msgs = REPLy.dispatch_middleware(eval_stack, 1,
        Dict("op" => "eval", "id" => "sl1", "session" => "post-burst",
             "code" => "42", "silent" => true), sl_ctx)
    @test !any(m -> haskey(m, "value"), sl_msgs)

    @test state.active_evals[] == 0
end
