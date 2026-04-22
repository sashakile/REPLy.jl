@testset "integration: named session lifecycle" begin
    @testset "named session persists bindings across lookups" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "persist-test")
        mod = REPLy.session_module(session)
        Core.eval(mod, :(acc = 0))

        # Simulate second access via lookup
        found = REPLy.lookup_named_session(manager, "persist-test")
        @test found !== nothing
        Core.eval(REPLy.session_module(found), :(acc += 1))
        @test Core.eval(mod, :acc) == 1
    end

    @testset "named sessions are isolated from ephemeral eval flow" begin
        manager = REPLy.SessionManager()
        named = REPLy.create_named_session!(manager, "isolated")

        # Plant a sentinel binding in the named session's module
        named_mod = REPLy.session_module(named)
        Core.eval(named_mod, :(sentinel = 42))

        @test REPLy.session_count(manager) == 0
        handler = REPLy.build_handler(; manager=manager)
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "lifecycle-ephemeral",
            "code" => "1 + 1",
        ))
        @test REPLy.session_count(manager) == 0  # ephemeral cleaned up

        # Named session unaffected — both registry and module bindings
        @test REPLy.lookup_named_session(manager, "isolated") !== nothing
        @test length(REPLy.list_named_sessions(manager)) == 1
        @test Core.eval(named_mod, :sentinel) == 42
    end

    @testset "destroying named session removes it from list" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "to-remove")
        REPLy.create_named_session!(manager, "to-keep")

        REPLy.destroy_named_session!(manager, "to-remove")
        names = REPLy.session_name.(REPLy.list_named_sessions(manager))
        @test !("to-remove" in names)
        @test "to-keep" in names
    end

    @testset "named session routing: request with session key resolves named session" begin
        manager = REPLy.SessionManager()
        named = REPLy.create_named_session!(manager, "routed")
        named_mod = REPLy.session_module(named)
        Core.eval(named_mod, :(counter = 10))

        handler = REPLy.build_handler(; manager=manager)

        # Eval in the named session — should see and mutate the binding
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "route-named-1",
            "code" => "counter += 1; counter",
            "session" => "routed",
        ))

        # The value response should contain "11"
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test !isempty(value_msg)
        @test value_msg[1]["value"] == "11"

        # Verify the named session module was actually mutated
        @test Core.eval(named_mod, :counter) == 11

        # Ephemeral session count should remain 0 — no ephemeral was created
        @test REPLy.session_count(manager) == 0
    end

    @testset "fallback ephemeral routing: request without session key uses ephemeral" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "persistent")

        handler = REPLy.build_handler(; manager=manager)

        # No "session" key — should use ephemeral session
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "ephemeral-fallback-1",
            "code" => "x = 42; x",
        ))

        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test !isempty(value_msg)
        @test value_msg[1]["value"] == "42"

        # Ephemeral session cleaned up
        @test REPLy.session_count(manager) == 0

        # Named session untouched — no binding leakage
        named = REPLy.lookup_named_session(manager, "persistent")
        named_mod = REPLy.session_module(named)
        @test !isdefined(named_mod, :x)
    end

    @testset "non-eval op with session key routes through named session lookup" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        # A non-eval op ("ls-sessions") that carries a session key pointing to a
        # non-existent session should still trigger session-not-found — session
        # routing is intentionally op-agnostic.
        msgs = handler(Dict(
            "op" => "ls-sessions",
            "id" => "non-eval-session-1",
            "session" => "no-such-session",
        ))

        terminal = filter(m -> haskey(m, "status"), msgs)
        @test !isempty(terminal)
        statuses = terminal[end]["status"]
        @test "error" in statuses
        @test "session-not-found" in statuses
    end

    @testset "non-eval op with valid session key resolves successfully" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "valid-for-non-eval")
        handler = REPLy.build_handler(; manager=manager)

        # A non-eval op with a valid session key should pass through without error.
        # The unknown op handler will process it, but no session-not-found occurs.
        msgs = handler(Dict(
            "op" => "ls-sessions",
            "id" => "non-eval-session-2",
            "session" => "valid-for-non-eval",
        ))

        # Should NOT contain a session-not-found error
        error_msgs = filter(m -> haskey(m, "status") && "session-not-found" in get(m, "status", []), msgs)
        @test isempty(error_msgs)
    end

    @testset "close_server! accepts grace_seconds and closes within budget" begin
        server = REPLy.serve(; port=0)

        t0 = time()
        close(server; grace_seconds=5.0)
        elapsed = time() - t0

        @test elapsed < 5.0  # no stuck clients — should close almost instantly
    end

    @testset "close_server! rejects non-positive grace_seconds" begin
        server = REPLy.serve(; port=0)
        @test_throws ArgumentError close(server; grace_seconds=0.0)
        close(server)  # cleanup
    end

    @testset "session-not-found: request with non-existent session returns error" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "eval",
            "id" => "missing-session-1",
            "code" => "1 + 1",
            "session" => "does-not-exist",
        ))

        # Should contain an error response with session-not-found status
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test !isempty(terminal)
        statuses = terminal[end]["status"]
        @test "error" in statuses
        @test "session-not-found" in statuses

        # Should NOT have created any ephemeral sessions
        @test REPLy.session_count(manager) == 0
    end
end
