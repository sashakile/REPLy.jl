@testset "persistent stdin feeder for named sessions" begin
    make_eval_stack() = REPLy.AbstractMiddleware[
        REPLy.SessionMiddleware(),
        REPLy.EvalMiddleware(),
        REPLy.UnknownOpMiddleware(),
    ]
    make_stdin_stack() = REPLy.AbstractMiddleware[
        REPLy.StdinMiddleware(),
        REPLy.UnknownOpMiddleware(),
    ]

    function eval_in(manager, session_name, code; id="fe")
        stack = make_eval_stack()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        REPLy.dispatch_middleware(stack, 1, Dict("op" => "eval", "id" => id, "session" => session_name, "code" => code), ctx)
    end

    function lookup(manager, name)
        REPLy.lookup_named_session(manager, name)
    end

    @testset "first allow_stdin eval creates session.stdin_pipe" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "feeder-1")
        @test isnothing(session.stdin_pipe)
        eval_in(manager, "feeder-1", "1"; id="fe1")
        @test !isnothing(session.stdin_pipe)
    end

    @testset "consecutive evals reuse the same pipe object" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "feeder-2")
        eval_in(manager, "feeder-2", "1"; id="fe2a")
        pipe_first = session.stdin_pipe
        eval_in(manager, "feeder-2", "2"; id="fe2b")
        @test session.stdin_pipe === pipe_first
    end

    @testset "feeder task stays alive across multiple evals" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "feeder-3")
        for i in 1:3
            eval_in(manager, "feeder-3", "$i"; id="fe3-$i")
        end
        @test !isnothing(session.stdin_feeder)
        @test !istaskdone(session.stdin_feeder)
    end

    @testset "allow_stdin=false does not create a persistent pipe" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "feeder-4")
        stack = make_eval_stack()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        REPLy.dispatch_middleware(stack, 1, Dict("op" => "eval", "id" => "fe4", "session" => "feeder-4", "allow-stdin" => false, "code" => "1"), ctx)
        @test isnothing(session.stdin_pipe)
    end

    @testset "stdin still works correctly on second eval using reused pipe" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "feeder-5")

        eval_stack = make_eval_stack()
        stdin_stack = make_stdin_stack()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)

        for round in 1:2
            code = "readline()"
            input = "line-$round\n"
            expected = "\"line-$round\""

            done_ch = Channel{Vector{Dict{String,Any}}}(1)
            @async begin
                eval_ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
                msgs = REPLy.dispatch_middleware(eval_stack, 1,
                    Dict("op" => "eval", "id" => "fe5-$round", "session" => "feeder-5", "code" => code), eval_ctx)
                put!(done_ch, msgs)
            end

            timeout = time() + 5.0
            while REPLy.session_state(lookup(manager, "feeder-5")) !== REPLy.SessionRunning
                yield()
                time() > timeout && error("timed out waiting for eval round $round")
            end

            REPLy.dispatch_middleware(stdin_stack, 1,
                Dict("op" => "stdin", "id" => "s5-$round", "session" => "feeder-5", "input" => input), ctx)

            msgs = timedwait(() -> isready(done_ch), 5.0) === :ok ? take!(done_ch) : nothing
            @test !isnothing(msgs)
            @test any(m -> get(m, "value", nothing) == expected, msgs)
        end
    end

    @testset "feeder task is finished after session is destroyed" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "feeder-6")
        eval_in(manager, "feeder-6", "1"; id="fe6")
        feeder = session.stdin_feeder
        @test !isnothing(feeder)
        @test !istaskdone(feeder)
        REPLy.destroy_named_session!(manager, "feeder-6")
        timedwait(() -> istaskdone(feeder), 2.0)
        @test istaskdone(feeder)
    end
end
