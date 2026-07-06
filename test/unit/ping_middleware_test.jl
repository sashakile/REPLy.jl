@testset "ping middleware" begin
    @testset "ping returns status [done, pong] without a session or eval" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.PingMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "ping", "id" => "p1"), ctx)

        @test length(msgs) == 1
        @test msgs[1]["id"] == "p1"
        @test msgs[1]["status"] == ["done", "pong"]
        # No session was created as a side effect.
        @test REPLy.total_session_count(manager) == 0
    end

    @testset "ping forwards non-ping ops to the next middleware" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.PingMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "not-a-real-op", "id" => "p2"), ctx)

        @test "error" in msgs[end]["status"]
    end

    @testset "ping is provided by the default middleware stack" begin
        handler = REPLy.build_handler()
        responses = handler(Dict("op" => "ping", "id" => "p3"))
        @test length(responses) == 1
        @test responses[1]["status"] == ["done", "pong"]
    end
end
