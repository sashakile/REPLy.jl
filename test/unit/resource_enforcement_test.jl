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

@testset "Resource enforcement — rate limiting and oversized messages" begin

    @testset "ResourceLimits has rate_limit_per_min field with default 600" begin
        limits = REPLy.ResourceLimits()
        @test limits.rate_limit_per_min == 600
    end

    @testset "rate_limit_per_min is overridable" begin
        limits = REPLy.ResourceLimits(rate_limit_per_min=10)
        @test limits.rate_limit_per_min == 10
    end

    @testset "handle_client! rejects requests beyond rate_limit_per_min" begin
        listener = listen(ip"127.0.0.1", 0)
        port = Int(getsockname(listener)[2])

        server_task = @async begin
            socket = accept(listener)
            try
                REPLy.handle_client!(socket, msg -> [REPLy.done_response(String(get(msg, "id", "")))];
                    rate_limit_per_min=2,
                )
            finally
                close(listener)
            end
        end

        client = connect(port)
        try
            # First two requests — should succeed
            for i in 1:2
                send_request(client, Dict("op" => "eval", "id" => "r$i", "code" => "1"))
                msgs = collect_until_done(client)
                @test !("rate-limited" in last(msgs)["status"])
            end

            # Third request — should be rate-limited
            send_request(client, Dict("op" => "eval", "id" => "r3", "code" => "1"))
            msgs = collect_until_done(client)
            terminal = last(msgs)
            @test "rate-limited" in terminal["status"]
            @test "error"        in terminal["status"]
            @test "done"         in terminal["status"]
            @test terminal["err"] == "Rate limit exceeded"
        finally
            isopen(client) && close(client)
            wait(server_task)
        end
    end

    @testset "oversized message via serve() returns error response" begin
        server = REPLy.serve(; port=0, max_message_bytes=100)
        port   = REPLy.server_port(server)

        try
            client = connect(port)
            try
                # Send a message that exceeds the 100-byte limit
                big_msg = Dict("op" => "eval", "id" => "big1", "code" => repeat("x", 200))
                send_request(client, big_msg)

                msgs = collect_until_done(client)
                @test length(msgs) == 1
                @test "error" in msgs[1]["status"]
                @test occursin("maximum size", msgs[1]["err"])
            finally
                isopen(client) && close(client)
            end
        finally
            close(server)
        end
    end

    @testset "rate limit via serve() limits requests per connection" begin
        limits = REPLy.ResourceLimits(rate_limit_per_min=1)
        server = REPLy.serve(; port=0, limits=limits)
        port   = REPLy.server_port(server)

        try
            client = connect(port)
            try
                # First request — allowed
                send_request(client, Dict("op" => "eval", "id" => "rl1", "code" => "42"))
                first_msgs = collect_until_done(client)
                @test !("rate-limited" in last(first_msgs)["status"])

                # Second request — rate limited
                send_request(client, Dict("op" => "eval", "id" => "rl2", "code" => "42"))
                second_msgs = collect_until_done(client)
                @test "rate-limited" in last(second_msgs)["status"]
            finally
                isopen(client) && close(client)
            end
        finally
            close(server)
        end
    end

end
