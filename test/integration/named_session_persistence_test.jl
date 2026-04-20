@testset "integration: named session eval persistence" begin
    @testset "variable defined in one eval is visible in the next" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "persist")
        handler = REPLy.build_handler(; manager=manager)

        # First eval: define a variable
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "persist-1",
            "code" => "greeting = \"hello\"",
            "session" => "persist",
        ))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test !isempty(value_msg)
        @test value_msg[1]["value"] == "\"hello\""

        # Second eval: read the variable back
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "persist-2",
            "code" => "greeting",
            "session" => "persist",
        ))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test !isempty(value_msg)
        @test value_msg[1]["value"] == "\"hello\""
    end

    @testset "multiple bindings accumulate across evals" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "accumulate")
        handler = REPLy.build_handler(; manager=manager)

        # Define multiple bindings across separate eval calls
        handler(Dict("op" => "eval", "id" => "acc-1", "code" => "a = 1", "session" => "accumulate"))
        handler(Dict("op" => "eval", "id" => "acc-2", "code" => "b = 2", "session" => "accumulate"))
        handler(Dict("op" => "eval", "id" => "acc-3", "code" => "c = 3", "session" => "accumulate"))

        # Fourth eval uses all three bindings
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "acc-4",
            "code" => "a + b + c",
            "session" => "accumulate",
        ))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test !isempty(value_msg)
        @test value_msg[1]["value"] == "6"
    end

    @testset "function definitions persist across evals" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "func-persist")
        handler = REPLy.build_handler(; manager=manager)

        # Define a function
        handler(Dict(
            "op" => "eval",
            "id" => "fn-1",
            "code" => "double(x) = 2x",
            "session" => "func-persist",
        ))

        # Call it in a subsequent eval
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "fn-2",
            "code" => "double(21)",
            "session" => "func-persist",
        ))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test !isempty(value_msg)
        @test value_msg[1]["value"] == "42"
    end

    @testset "named session bindings are isolated from ephemeral evals" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "isolated-persist")
        handler = REPLy.build_handler(; manager=manager)

        # Define a variable in the named session
        handler(Dict(
            "op" => "eval",
            "id" => "iso-1",
            "code" => "secret = 99",
            "session" => "isolated-persist",
        ))

        # Ephemeral eval should NOT see the named session's variable
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "iso-2",
            "code" => "secret",
        ))
        # Should be an error (UndefVarError)
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test !isempty(terminal)
        @test "error" in terminal[end]["status"]

        # Named session still has the variable
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "iso-3",
            "code" => "secret",
            "session" => "isolated-persist",
        ))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test !isempty(value_msg)
        @test value_msg[1]["value"] == "99"
    end

    @testset "two named sessions have independent bindings" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "session-a")
        REPLy.create_named_session!(manager, "session-b")
        handler = REPLy.build_handler(; manager=manager)

        # Define x in session-a
        handler(Dict("op" => "eval", "id" => "ab-1", "code" => "x = 10", "session" => "session-a"))

        # Define x in session-b (different value)
        handler(Dict("op" => "eval", "id" => "ab-2", "code" => "x = 20", "session" => "session-b"))

        # Read x from session-a — should still be 10
        msgs = handler(Dict("op" => "eval", "id" => "ab-3", "code" => "x", "session" => "session-a"))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test value_msg[1]["value"] == "10"

        # Read x from session-b — should be 20
        msgs = handler(Dict("op" => "eval", "id" => "ab-4", "code" => "x", "session" => "session-b"))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test value_msg[1]["value"] == "20"
    end

    @testset "mutable state persists correctly" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "mutable")
        handler = REPLy.build_handler(; manager=manager)

        # Create a mutable container
        handler(Dict("op" => "eval", "id" => "mut-1", "code" => "items = Int[]", "session" => "mutable"))

        # Mutate it across evals
        handler(Dict("op" => "eval", "id" => "mut-2", "code" => "push!(items, 1)", "session" => "mutable"))
        handler(Dict("op" => "eval", "id" => "mut-3", "code" => "push!(items, 2)", "session" => "mutable"))
        handler(Dict("op" => "eval", "id" => "mut-4", "code" => "push!(items, 3)", "session" => "mutable"))

        # Read the accumulated state
        msgs = handler(Dict("op" => "eval", "id" => "mut-5", "code" => "items", "session" => "mutable"))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test !isempty(value_msg)
        @test value_msg[1]["value"] == "[1, 2, 3]"
    end
end
