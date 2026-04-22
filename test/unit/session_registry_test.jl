@testset "named session registry" begin
    @testset "create_named_session! registers a session by name" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "myapp")
        @test REPLy.session_name(session) == "myapp"
        @test REPLy.session_module(session) isa Module
    end

    @testset "list_named_sessions returns all named sessions" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "alpha")
        REPLy.create_named_session!(manager, "beta")
        sessions = REPLy.list_named_sessions(manager)
        names = REPLy.session_name.(sessions)
        @test "alpha" in names
        @test "beta" in names
        @test length(sessions) == 2
    end

    @testset "lookup_named_session returns session by name" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "found")
        session = REPLy.lookup_named_session(manager, "found")
        @test session !== nothing
        @test REPLy.session_name(session) == "found"
    end

    @testset "lookup_named_session returns nothing for unknown name" begin
        manager = REPLy.SessionManager()
        @test REPLy.lookup_named_session(manager, "ghost") === nothing
    end

    @testset "destroy_named_session! removes session from registry" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "temp")
        REPLy.destroy_named_session!(manager, "temp")
        @test REPLy.lookup_named_session(manager, "temp") === nothing
        @test isempty(REPLy.list_named_sessions(manager))
    end

    @testset "destroy_named_session! is idempotent" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "temp")
        REPLy.destroy_named_session!(manager, "temp")
        REPLy.destroy_named_session!(manager, "temp")  # no error
        @test isempty(REPLy.list_named_sessions(manager))
    end

    @testset "named sessions have creation timestamp metadata" begin
        t_before = time()
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "dated")
        t_after = time()
        @test REPLy.session_created_at(session) >= t_before
        @test REPLy.session_created_at(session) <= t_after
    end

    @testset "named session isolates bindings from other named sessions" begin
        manager = REPLy.SessionManager()
        alpha = REPLy.create_named_session!(manager, "alpha")
        beta = REPLy.create_named_session!(manager, "beta")

        ma = REPLy.session_module(alpha)
        mb = REPLy.session_module(beta)
        @test ma !== mb

        Core.eval(ma, :(x = 100))
        Core.eval(mb, :(x = 200))
        @test Core.eval(ma, :x) == 100
        @test Core.eval(mb, :x) == 200
    end

    @testset "invariant: ephemeral sessions never appear in list_named_sessions" begin
        manager = REPLy.SessionManager()
        REPLy.create_ephemeral_session!(manager)
        REPLy.create_ephemeral_session!(manager)
        REPLy.create_named_session!(manager, "persistent")
        named = REPLy.list_named_sessions(manager)
        @test length(named) == 1
        @test REPLy.session_name(only(named)) == "persistent"
    end

    @testset "create_named_session! replaces existing session with same name" begin
        manager = REPLy.SessionManager()
        old = REPLy.create_named_session!(manager, "dup")
        old_mod = REPLy.session_module(old)
        Core.eval(old_mod, :(marker = :old))

        replacement = REPLy.create_named_session!(manager, "dup")
        @test replacement !== old
        @test REPLy.session_module(replacement) !== old_mod

        found = REPLy.lookup_named_session(manager, "dup")
        @test found === replacement
        @test length(REPLy.list_named_sessions(manager)) == 1
    end

    @testset "clone_named_session! deep-copies mutable values" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "src")
        Core.eval(REPLy.session_module(source), :(arr = [1, 2, 3]))

        clone = REPLy.clone_named_session!(manager, "src", "dst")
        @test clone !== nothing

        # Mutate the array in the clone
        Core.eval(REPLy.session_module(clone), :(push!(arr, 4)))

        # Original must be unaffected
        @test Core.eval(REPLy.session_module(source), :arr) == [1, 2, 3]
        @test Core.eval(REPLy.session_module(clone), :arr) == [1, 2, 3, 4]
    end

    @testset "clone_named_session! throws when dest_name already exists" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "existing-src")
        REPLy.create_named_session!(manager, "existing-dst")

        @test_throws ArgumentError REPLy.clone_named_session!(manager, "existing-src", "existing-dst")
        # Both sessions should still be intact
        @test REPLy.lookup_named_session(manager, "existing-src") !== nothing
        @test REPLy.lookup_named_session(manager, "existing-dst") !== nothing
    end

    @testset "clone_named_session! skips Module-typed bindings without throwing" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "mod-src")
        # Bind a module into the session — deepcopy of Module throws, so this
        # exercises the skip guard.
        Core.eval(REPLy.session_module(source), :(import Base; m = Base))

        clone = REPLy.clone_named_session!(manager, "mod-src", "mod-dst")
        @test clone !== nothing
        # The Module binding is skipped, so it will be undefined in the clone.
        @test !isdefined(REPLy.session_module(clone), :m)
    end

    @testset "concurrent create and destroy do not corrupt state" begin
        manager = REPLy.SessionManager()
        n = 10
        tasks = [
            @async begin
                for i in 1:20
                    name = "concurrent-$(Threads.threadid())-$i"
                    REPLy.create_named_session!(manager, name)
                    REPLy.destroy_named_session!(manager, name)
                end
            end
            for _ in 1:n
        ]
        foreach(wait, tasks)
        # After all tasks complete, the registry should not contain any leftover entries
        # from this test (all were created and then destroyed).
        leftover = filter(s -> startswith(REPLy.session_name(s), "concurrent-"), REPLy.list_named_sessions(manager))
        @test isempty(leftover)
    end

    @testset "ephemeral session count unaffected by named sessions" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "named1")
        REPLy.create_named_session!(manager, "named2")
        ephemeral = REPLy.create_ephemeral_session!(manager)
        @test REPLy.session_count(manager) == 1  # only ephemeral
        REPLy.destroy_session!(manager, ephemeral)
        @test REPLy.session_count(manager) == 0
    end
end
