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
end
