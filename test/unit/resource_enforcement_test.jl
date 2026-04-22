@testset "Resource enforcement — session count and concurrent eval limits" begin

    @testset "ResourceLimits has max_sessions and max_concurrent_evals fields" begin
        limits = REPLy.ResourceLimits()
        @test limits.max_sessions        == 100
        @test limits.max_concurrent_evals == 10
    end

    @testset "max_sessions and max_concurrent_evals are overridable" begin
        limits = REPLy.ResourceLimits(max_sessions=5, max_concurrent_evals=2)
        @test limits.max_sessions        == 5
        @test limits.max_concurrent_evals == 2
    end

    @testset "ServerState exposes active_evals counter" begin
        limits = REPLy.ResourceLimits()
        state  = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        @test state.active_evals[] == 0
    end

    @testset "clone-session rejected when session limit reached" begin
        # Build a handler that enforces max_sessions=2 via limits
        limits  = REPLy.ResourceLimits(max_sessions=2)
        manager = REPLy.SessionManager()
        state   = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)

        # Pre-populate 2 named sessions directly so we hit the limit
        REPLy.create_named_session!(manager, "s1")
        REPLy.create_named_session!(manager, "s2")

        middleware = REPLy.default_middleware_stack()
        handler    = REPLy.build_handler(; manager=manager, middleware=middleware, state=state)

        responses = handler(Dict("op" => "clone-session", "source" => "s1", "name" => "s3", "id" => "t1"))
        terminal  = last(responses)

        @test "session-limit-reached" in terminal["status"]
        @test "error" in terminal["status"]
        @test "done"  in terminal["status"]
    end

    @testset "eval rejected when session limit reached for ephemeral session" begin
        limits  = REPLy.ResourceLimits(max_sessions=0)
        manager = REPLy.SessionManager()
        state   = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)

        middleware = REPLy.default_middleware_stack()
        handler    = REPLy.build_handler(; manager=manager, middleware=middleware, state=state)

        responses = handler(Dict("op" => "eval", "code" => "1+1", "id" => "t2"))
        terminal  = last(responses)

        @test "session-limit-reached" in terminal["status"]
        @test "error" in terminal["status"]
    end

    @testset "eval rejected when concurrent eval limit reached" begin
        limits  = REPLy.ResourceLimits(max_concurrent_evals=0)
        manager = REPLy.SessionManager()
        state   = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)

        middleware = REPLy.default_middleware_stack()
        handler    = REPLy.build_handler(; manager=manager, middleware=middleware, state=state)

        responses = handler(Dict("op" => "eval", "code" => "1+1", "id" => "t3"))
        terminal  = last(responses)

        @test "concurrency-limit-reached" in terminal["status"]
        @test "error" in terminal["status"]
    end

    @testset "active_evals counter increments and decrements around eval" begin
        limits  = REPLy.ResourceLimits(max_concurrent_evals=10)
        manager = REPLy.SessionManager()
        state   = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)

        middleware = REPLy.default_middleware_stack()
        handler    = REPLy.build_handler(; manager=manager, middleware=middleware, state=state)

        @test state.active_evals[] == 0
        handler(Dict("op" => "eval", "code" => "2+2", "id" => "t4"))
        @test state.active_evals[] == 0  # decremented after eval
    end

    @testset "create_named_session! rejected when session limit reached" begin
        limits  = REPLy.ResourceLimits(max_sessions=1)
        manager = REPLy.SessionManager()
        state   = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)

        # Fill up to limit
        REPLy.create_named_session!(manager, "s1")

        middleware = REPLy.default_middleware_stack()
        handler    = REPLy.build_handler(; manager=manager, middleware=middleware, state=state)

        # Attempt to create another via clone
        responses = handler(Dict("op" => "clone-session", "source" => "s1", "name" => "s2", "id" => "t5"))
        terminal  = last(responses)

        @test "session-limit-reached" in terminal["status"]
    end

end
