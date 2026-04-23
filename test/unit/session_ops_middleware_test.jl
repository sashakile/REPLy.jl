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

    @testset "session name validation rejects invalid names with format error" begin
        handler = REPLy.build_handler()

        for (label, name) in [
            ("whitespace-only", "   "),
            ("disallowed chars", "my session!"),
            ("dot in name", "my.session"),
            ("slash in name", "a/b"),
        ]
            msgs = handler(Dict("op" => "close-session", "id" => "val-$label", "name" => name))
            assert_conformance(msgs, "val-$label")
            terminal = filter(m -> haskey(m, "status"), msgs)[end]
            @test "error" in terminal["status"]
            # Must be a format error, not a "session not found" error
            @test !("session-not-found" in terminal["status"])
        end
    end

    @testset "session name validation rejects names over max length" begin
        handler = REPLy.build_handler()
        long_name = repeat("a", REPLy.MAX_SESSION_NAME_BYTES + 1)
        msgs = handler(Dict("op" => "close-session", "id" => "val-long", "name" => long_name))
        assert_conformance(msgs, "val-long")
        terminal = filter(m -> haskey(m, "status"), msgs)[end]
        @test "error" in terminal["status"]
        @test !("session-not-found" in terminal["status"])
    end

    @testset "session name validation accepts valid names" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        for name in ["alpha", "my-session", "session_1", "ABC-123"]
            REPLy.create_named_session!(manager, name)
            msgs = handler(Dict("op" => "close-session", "id" => "val-ok-$name", "name" => name))
            assert_conformance(msgs, "val-ok-$name")
            @test !("error" in filter(m -> haskey(m, "status"), msgs)[end]["status"])
        end
    end

    @testset "session routing rejects invalid session name before lookup" begin
        handler = REPLy.build_handler()
        msgs = handler(Dict("op" => "eval", "id" => "route-bad", "session" => "bad name!", "code" => "1+1"))
        assert_conformance(msgs, "route-bad")
        terminal = filter(m -> haskey(m, "status"), msgs)[end]
        @test "error" in terminal["status"]
        @test !("session-not-found" in terminal["status"])
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

@testset "hybrid session identity (UUID + name alias)" begin
    @testset "new-session without name returns UUID and null name" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "new-session", "id" => "ns-anon"))

        assert_conformance(msgs, "ns-anon")
        resp = filter(m -> haskey(m, "session"), msgs)
        @test length(resp) == 1
        @test resp[1]["session"] isa AbstractString
        @test length(resp[1]["session"]) == 36  # UUID length
        @test resp[1]["name"] === nothing
    end

    @testset "new-session with name returns UUID and alias" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "new-session", "id" => "ns-named", "name" => "myapp"))

        assert_conformance(msgs, "ns-named")
        resp = filter(m -> haskey(m, "session"), msgs)
        @test length(resp) == 1
        @test resp[1]["session"] isa AbstractString
        @test length(resp[1]["session"]) == 36
        @test resp[1]["name"] == "myapp"
    end

    @testset "new-session creates session accessible by returned UUID" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "new-session", "id" => "ns-uuid-lookup", "name" => "lookup-test"))
        resp = filter(m -> haskey(m, "session"), msgs)
        uuid = resp[1]["session"]

        # Session should be accessible by UUID
        session = REPLy.lookup_named_session(manager, uuid)
        @test !isnothing(session)
        @test REPLy.session_id(session) == uuid
        @test REPLy.session_name(session) == "lookup-test"
    end

    @testset "new-session creates session accessible by name alias" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "new-session", "id" => "ns-name-lookup", "name" => "named-test"))
        resp = filter(m -> haskey(m, "session"), msgs)
        uuid = resp[1]["session"]

        # Session should be accessible by name alias
        session_by_name = REPLy.lookup_named_session(manager, "named-test")
        session_by_uuid = REPLy.lookup_named_session(manager, uuid)
        @test !isnothing(session_by_name)
        @test !isnothing(session_by_uuid)
        @test session_by_name === session_by_uuid
    end

    @testset "eval with UUID session identifier routes correctly" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "uuid-eval-test")
        uuid = REPLy.session_id(session)
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "eval",
            "id" => "uuid-eval-1",
            "code" => "x_uuid = 99",
            "session" => uuid,
        ))
        assert_conformance(msgs, "uuid-eval-1")
        @test any(get(m, "value", nothing) == "99" for m in msgs)
    end

    @testset "eval with name alias and UUID are interchangeable" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "interchangeable")
        uuid = REPLy.session_id(session)
        handler = REPLy.build_handler(; manager=manager)

        # Define variable using name alias
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "inter-1",
            "code" => "aliased_var = 7",
            "session" => "interchangeable",
        ))
        assert_conformance(msgs, "inter-1")
        @test any(get(m, "value", nothing) == "7" for m in msgs)

        # Read variable using UUID
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "inter-2",
            "code" => "aliased_var",
            "session" => uuid,
        ))
        assert_conformance(msgs, "inter-2")
        @test any(get(m, "value", nothing) == "7" for m in msgs)
    end

    @testset "close-session accepts UUID" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "close-by-uuid")
        uuid = REPLy.session_id(session)
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close-session", "id" => "close-uuid", "name" => uuid))
        assert_conformance(msgs, "close-uuid")
        @test REPLy.lookup_named_session(manager, uuid) === nothing
        @test REPLy.lookup_named_session(manager, "close-by-uuid") === nothing
    end

    @testset "close-session accepts name alias" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "close-by-name")
        uuid = REPLy.session_id(session)
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close-session", "id" => "close-name", "name" => "close-by-name"))
        assert_conformance(msgs, "close-name")
        @test REPLy.lookup_named_session(manager, uuid) === nothing
        @test REPLy.lookup_named_session(manager, "close-by-name") === nothing
    end

    @testset "clone-session source accepts UUID" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "clone-src-uuid")
        uuid = REPLy.session_id(source)
        Core.eval(REPLy.session_module(source), :(uuid_val = 55))
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "clone-session",
            "id" => "clone-by-uuid",
            "source" => uuid,
            "name" => "cloned-from-uuid",
        ))
        assert_conformance(msgs, "clone-by-uuid")
        resp = filter(m -> haskey(m, "session"), msgs)
        @test !isempty(resp)
        clone = REPLy.lookup_named_session(manager, "cloned-from-uuid")
        @test !isnothing(clone)
        @test Core.eval(REPLy.session_module(clone), :uuid_val) == 55
    end

    @testset "ls-sessions response includes UUID session field" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "ls-uuid-test")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "ls-sessions", "id" => "ls-with-uuid"))
        assert_conformance(msgs, "ls-with-uuid")
        sessions_msg = filter(m -> haskey(m, "sessions"), msgs)
        sessions = sessions_msg[1]["sessions"]
        @test length(sessions) == 1
        @test haskey(sessions[1], "session")
        @test length(sessions[1]["session"]) == 36  # UUID length
        @test sessions[1]["name"] == "ls-uuid-test"
        @test haskey(sessions[1], "created-at")
    end

    @testset "ls-sessions session with no alias has null name" begin
        manager = REPLy.SessionManager()
        # Create a session with empty name (no alias)
        REPLy.create_named_session!(manager, "")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "ls-sessions", "id" => "ls-no-alias"))
        sessions_msg = filter(m -> haskey(m, "sessions"), msgs)
        sessions = sessions_msg[1]["sessions"]
        @test length(sessions) == 1
        @test haskey(sessions[1], "session")
        @test sessions[1]["name"] === nothing
    end

    @testset "new-session rejects invalid name" begin
        handler = REPLy.build_handler()

        msgs = handler(Dict("op" => "new-session", "id" => "ns-bad-name", "name" => "bad name!"))
        assert_conformance(msgs, "ns-bad-name")
        terminal = filter(m -> haskey(m, "status"), msgs)[end]
        @test "error" in terminal["status"]
        @test !("session-not-found" in terminal["status"])
    end

    @testset "new-session rejects empty name string (use no name field for unnamed session)" begin
        handler = REPLy.build_handler()

        # Explicit empty string is rejected — omit the "name" field entirely for an unnamed session
        msgs = handler(Dict("op" => "new-session", "id" => "ns-empty-name", "name" => ""))
        assert_conformance(msgs, "ns-empty-name")
        terminal = filter(m -> haskey(m, "status"), msgs)[end]
        @test "error" in terminal["status"]
    end
end
