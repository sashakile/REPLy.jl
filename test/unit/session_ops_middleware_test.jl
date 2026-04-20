@testset "session ops middleware" begin
    @testset "ls-sessions returns empty list when no named sessions exist" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "ls-sessions", "id" => "ls-empty"))

        assert_conformance(msgs, "ls-empty")
        sessions_msg = filter(m -> haskey(m, "sessions"), msgs)
        @test length(sessions_msg) == 1
        @test sessions_msg[1]["sessions"] == []
    end

    @testset "ls-sessions returns all named sessions with metadata" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "alpha")
        REPLy.create_named_session!(manager, "beta")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "ls-sessions", "id" => "ls-two"))

        assert_conformance(msgs, "ls-two")
        sessions_msg = filter(m -> haskey(m, "sessions"), msgs)
        @test length(sessions_msg) == 1
        sessions = sessions_msg[1]["sessions"]
        @test length(sessions) == 2
        names = [s["name"] for s in sessions]
        @test "alpha" in names
        @test "beta" in names
        @test all(haskey(s, "created-at") for s in sessions)
    end

    @testset "ls-sessions does not include ephemeral sessions" begin
        manager = REPLy.SessionManager()
        REPLy.create_ephemeral_session!(manager)
        REPLy.create_named_session!(manager, "only-named")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "ls-sessions", "id" => "ls-no-eph"))

        sessions_msg = filter(m -> haskey(m, "sessions"), msgs)
        sessions = sessions_msg[1]["sessions"]
        @test length(sessions) == 1
        @test sessions[1]["name"] == "only-named"
    end

    @testset "close-session destroys a named session" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "to-close")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close-session", "id" => "close-1", "name" => "to-close"))

        assert_conformance(msgs, "close-1")
        @test REPLy.lookup_named_session(manager, "to-close") === nothing
        @test isempty(REPLy.list_named_sessions(manager))
    end

    @testset "close-session returns error for non-existent session" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close-session", "id" => "close-missing", "name" => "ghost"))

        assert_conformance(msgs, "close-missing")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test !isempty(terminal)
        @test "error" in terminal[end]["status"]
        @test "session-not-found" in terminal[end]["status"]
    end

    @testset "close-session requires name parameter" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close-session", "id" => "close-no-name"))

        assert_conformance(msgs, "close-no-name")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "error" in terminal[end]["status"]
        @test occursin("name", terminal[end]["err"])
    end

    @testset "close-session preserves other named sessions" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "keep")
        REPLy.create_named_session!(manager, "remove")
        handler = REPLy.build_handler(; manager=manager)

        handler(Dict("op" => "close-session", "id" => "close-selective", "name" => "remove"))

        @test REPLy.lookup_named_session(manager, "keep") !== nothing
        @test REPLy.lookup_named_session(manager, "remove") === nothing
    end

    @testset "clone-session creates a new session with copied bindings" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "original")
        Core.eval(REPLy.session_module(source), :(x = 42))
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "clone-session",
            "id" => "clone-1",
            "source" => "original",
            "name" => "copy",
        ))

        assert_conformance(msgs, "clone-1")
        clone = REPLy.lookup_named_session(manager, "copy")
        @test clone !== nothing
        @test REPLy.session_name(clone) == "copy"
        @test Core.eval(REPLy.session_module(clone), :x) == 42
    end

    @testset "clone-session creates an independent copy (mutations do not leak back)" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "src")
        Core.eval(REPLy.session_module(source), :(counter = 10))
        handler = REPLy.build_handler(; manager=manager)

        handler(Dict(
            "op" => "clone-session",
            "id" => "clone-indep",
            "source" => "src",
            "name" => "dst",
        ))

        # Mutate the clone
        clone = REPLy.lookup_named_session(manager, "dst")
        Core.eval(REPLy.session_module(clone), :(counter += 100))

        # Original is unchanged
        @test Core.eval(REPLy.session_module(source), :counter) == 10
        @test Core.eval(REPLy.session_module(clone), :counter) == 110
    end

    @testset "clone-session returns error for non-existent source" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "clone-session",
            "id" => "clone-missing-src",
            "source" => "no-such-session",
            "name" => "new-copy",
        ))

        assert_conformance(msgs, "clone-missing-src")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "error" in terminal[end]["status"]
        @test "session-not-found" in terminal[end]["status"]
    end

    @testset "clone-session requires source and name parameters" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        # Missing source
        msgs = handler(Dict("op" => "clone-session", "id" => "clone-no-src", "name" => "dest"))
        assert_conformance(msgs, "clone-no-src")
        @test "error" in filter(m -> haskey(m, "status"), msgs)[end]["status"]

        # Missing name
        msgs = handler(Dict("op" => "clone-session", "id" => "clone-no-name", "source" => "src"))
        assert_conformance(msgs, "clone-no-name")
        @test "error" in filter(m -> haskey(m, "status"), msgs)[end]["status"]
    end

    @testset "clone-session deep-copies mutable containers" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "mut-src")
        Core.eval(REPLy.session_module(source), :(data = Dict(:a => 1)))
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "clone-session",
            "id" => "clone-mutable",
            "source" => "mut-src",
            "name" => "mut-dst",
        ))
        assert_conformance(msgs, "clone-mutable")

        # Mutate the dict in the clone
        clone = REPLy.lookup_named_session(manager, "mut-dst")
        Core.eval(REPLy.session_module(clone), :(data[:b] = 2))

        # Original is unaffected
        orig_data = Core.eval(REPLy.session_module(source), :data)
        @test !haskey(orig_data, :b)
        @test orig_data == Dict(:a => 1)
    end

    @testset "clone-session returns error when destination already exists" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "src-exists")
        REPLy.create_named_session!(manager, "dst-exists")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "clone-session",
            "id" => "clone-dup",
            "source" => "src-exists",
            "name" => "dst-exists",
        ))

        assert_conformance(msgs, "clone-dup")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test !isempty(terminal)
        @test "error" in terminal[end]["status"]
        @test "session-already-exists" in terminal[end]["status"]
        @test occursin("dst-exists", terminal[end]["err"])

        # Both sessions should still be intact
        @test REPLy.lookup_named_session(manager, "src-exists") !== nothing
        @test REPLy.lookup_named_session(manager, "dst-exists") !== nothing
        @test length(REPLy.list_named_sessions(manager)) == 2
    end

    @testset "clone-session preserves original session" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "keeper")
        handler = REPLy.build_handler(; manager=manager)

        handler(Dict(
            "op" => "clone-session",
            "id" => "clone-keep",
            "source" => "keeper",
            "name" => "new-one",
        ))

        @test REPLy.lookup_named_session(manager, "keeper") !== nothing
        @test REPLy.lookup_named_session(manager, "new-one") !== nothing
        @test length(REPLy.list_named_sessions(manager)) == 2
    end
end
