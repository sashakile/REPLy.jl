@testset "store-history behavior" begin
    function make_ctx(manager)
        REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
    end

    function eval_stack()
        REPLy.AbstractMiddleware[
            REPLy.SessionMiddleware(),
            REPLy.EvalMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ]
    end

    @testset "successful eval sets ans in session module" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "ans-sess")
        ctx = make_ctx(manager)
        stack = eval_stack()

        REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "h1", "session" => "ans-sess", "code" => "42"), ctx)

        # Second eval reads ans
        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "h2", "session" => "ans-sess", "code" => "ans"), make_ctx(manager))

        value_msg = only(filter(m -> haskey(m, "value"), msgs))
        @test value_msg["value"] == "42"
    end

    @testset "store-history false skips ans" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "no-hist-sess")
        ctx = make_ctx(manager)
        stack = eval_stack()

        # Set ans to a known value first
        REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "h3a", "session" => "no-hist-sess", "code" => "99"), ctx)

        # Now eval with store-history=false — ans should stay 99
        REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "h3b", "session" => "no-hist-sess",
                 "store-history" => false, "code" => "1 + 1"), make_ctx(manager))

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "h3c", "session" => "no-hist-sess", "code" => "ans"), make_ctx(manager))

        value_msg = only(filter(m -> haskey(m, "value"), msgs))
        @test value_msg["value"] == "99"
    end

    @testset "failed eval does not update ans" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "fail-ans-sess")
        ctx = make_ctx(manager)
        stack = eval_stack()

        # Set ans to a known value
        REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "h4a", "session" => "fail-ans-sess", "code" => "55"), ctx)

        # Error eval — ans should stay 55
        REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "h4b", "session" => "fail-ans-sess",
                 "code" => "error(\"boom\")"), make_ctx(manager))

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "h4c", "session" => "fail-ans-sess", "code" => "ans"), make_ctx(manager))

        value_msg = only(filter(m -> haskey(m, "value"), msgs))
        @test value_msg["value"] == "55"
    end

    @testset "history grows on each successful eval" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "grow-sess")
        stack = eval_stack()

        for i in 1:3
            REPLy.dispatch_middleware(stack, 1,
                Dict("op" => "eval", "id" => "g$i", "session" => "grow-sess", "code" => "$i"), make_ctx(manager))
        end

        @test length(session.history) == 3
        @test session.history == [1, 2, 3]
    end

    @testset "store-history false skips history push" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "skip-hist-sess")
        stack = eval_stack()

        REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "s1", "session" => "skip-hist-sess", "code" => "1"), make_ctx(manager))

        REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "eval", "id" => "s2", "session" => "skip-hist-sess",
                 "store-history" => false, "code" => "2"), make_ctx(manager))

        @test length(session.history) == 1
        @test session.history[1] == 1
    end

    @testset "history is bounded at MAX_SESSION_HISTORY_SIZE" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "bounded-sess")
        stack = eval_stack()

        limit = REPLy.MAX_SESSION_HISTORY_SIZE
        # Fill history to just over the limit
        for i in 1:(limit + 5)
            push!(session.history, i)
        end
        REPLy.clamp_history!(session)

        @test length(session.history) == limit
        @test session.history[1] == 6  # oldest entries dropped
    end
end
