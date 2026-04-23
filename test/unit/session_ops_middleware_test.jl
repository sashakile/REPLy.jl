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

@testset "canonical op names: 'close' and 'clone' (OpenSpec protocol names)" begin
    @testset "close op destroys a named session" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "canon-close-target")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close", "id" => "canon-close-1", "name" => "canon-close-target"))

        assert_conformance(msgs, "canon-close-1")
        @test REPLy.lookup_named_session(manager, "canon-close-target") === nothing
        @test isempty(REPLy.list_named_sessions(manager))
    end

    @testset "close op returns error for non-existent session" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close", "id" => "canon-close-missing", "name" => "ghost"))

        assert_conformance(msgs, "canon-close-missing")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test !isempty(terminal)
        @test "error" in terminal[end]["status"]
        @test "session-not-found" in terminal[end]["status"]
    end

    @testset "close op requires name parameter" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close", "id" => "canon-close-no-name"))

        assert_conformance(msgs, "canon-close-no-name")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "error" in terminal[end]["status"]
        @test occursin("name", terminal[end]["err"])
    end

    @testset "clone op creates a new session with copied bindings" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "canon-original")
        Core.eval(REPLy.session_module(source), :(x = 42))
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "clone",
            "id" => "canon-clone-1",
            "source" => "canon-original",
            "name" => "canon-copy",
        ))

        assert_conformance(msgs, "canon-clone-1")
        clone = REPLy.lookup_named_session(manager, "canon-copy")
        @test clone !== nothing
        @test REPLy.session_name(clone) == "canon-copy"
        @test Core.eval(REPLy.session_module(clone), :x) == 42
    end

    @testset "clone op returns error for non-existent source" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "clone",
            "id" => "canon-clone-missing-src",
            "source" => "no-such-session",
            "name" => "new-copy",
        ))

        assert_conformance(msgs, "canon-clone-missing-src")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "error" in terminal[end]["status"]
        @test "session-not-found" in terminal[end]["status"]
    end

    @testset "clone op returns error when destination already exists" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "canon-src-exists")
        REPLy.create_named_session!(manager, "canon-dst-exists")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "clone",
            "id" => "canon-clone-dup",
            "source" => "canon-src-exists",
            "name" => "canon-dst-exists",
        ))

        assert_conformance(msgs, "canon-clone-dup")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test !isempty(terminal)
        @test "error" in terminal[end]["status"]
        @test "session-already-exists" in terminal[end]["status"]
    end

    @testset "deprecated 'close-session' still works (backward compat)" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "compat-close-target")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close-session", "id" => "compat-close-1", "name" => "compat-close-target"))

        assert_conformance(msgs, "compat-close-1")
        @test REPLy.lookup_named_session(manager, "compat-close-target") === nothing
    end

    @testset "deprecated 'clone-session' still works (backward compat)" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "compat-original")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "clone-session",
            "id" => "compat-clone-1",
            "source" => "compat-original",
            "name" => "compat-copy",
        ))

        assert_conformance(msgs, "compat-clone-1")
        clone = REPLy.lookup_named_session(manager, "compat-copy")
        @test clone !== nothing
    end
end

@testset "clone op: spec-compliant schema (REPLy_jl-ojy)" begin
    @testset "clone accepts 'session' field as source identifier" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "spec-src")
        Core.eval(REPLy.session_module(source), :(spec_val = 77))
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op"      => "clone",
            "id"      => "spec-clone-session-field",
            "session" => "spec-src",
            "name"    => "spec-dst",
        ))

        assert_conformance(msgs, "spec-clone-session-field")
        clone = REPLy.lookup_named_session(manager, "spec-dst")
        @test clone !== nothing
        @test Core.eval(REPLy.session_module(clone), :spec_val) == 77
    end

    @testset "clone with 'session' field returns 'new-session' UUID key in response" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "ns-src")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op"      => "clone",
            "id"      => "spec-clone-new-session-key",
            "session" => "ns-src",
            "name"    => "ns-dst",
        ))

        assert_conformance(msgs, "spec-clone-new-session-key")
        resp = filter(m -> haskey(m, "new-session"), msgs)
        @test !isempty(resp)
        @test resp[1]["new-session"] isa AbstractString
        @test length(resp[1]["new-session"]) == 36  # UUID length
        @test resp[1]["name"] == "ns-dst"
    end

    @testset "clone with 'source' field also returns 'new-session' UUID key (backward compat)" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "compat-ns-src")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op"    => "clone",
            "id"    => "spec-clone-source-compat",
            "source" => "compat-ns-src",
            "name"  => "compat-ns-dst",
        ))

        assert_conformance(msgs, "spec-clone-source-compat")
        resp = filter(m -> haskey(m, "new-session"), msgs)
        @test !isempty(resp)
        @test resp[1]["new-session"] isa AbstractString
        @test length(resp[1]["new-session"]) == 36
    end

    @testset "clone with type='light' succeeds" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "light-src")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op"      => "clone",
            "id"      => "spec-clone-light",
            "session" => "light-src",
            "name"    => "light-dst",
            "type"    => "light",
        ))

        assert_conformance(msgs, "spec-clone-light")
        clone = REPLy.lookup_named_session(manager, "light-dst")
        @test clone !== nothing
    end

    @testset "clone with type='heavy' returns not-supported error" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "heavy-src")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op"      => "clone",
            "id"      => "spec-clone-heavy",
            "session" => "heavy-src",
            "name"    => "heavy-dst",
            "type"    => "heavy",
        ))

        assert_conformance(msgs, "spec-clone-heavy")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test !isempty(terminal)
        @test "not-supported" in terminal[end]["status"]
        @test occursin("post-v1.0", get(terminal[end], "err", ""))
        # Session should NOT have been created
        @test REPLy.lookup_named_session(manager, "heavy-dst") === nothing
    end

    @testset "clone 'session' field falls back to 'source' when only source present" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "fallback-src")
        handler = REPLy.build_handler(; manager=manager)

        # Old-style request with 'source' only — must still work for the canonical 'clone' op
        msgs = handler(Dict(
            "op"    => "clone",
            "id"    => "spec-clone-fallback",
            "source" => "fallback-src",
            "name"  => "fallback-dst",
        ))

        assert_conformance(msgs, "spec-clone-fallback")
        @test REPLy.lookup_named_session(manager, "fallback-dst") !== nothing
    end

    @testset "clone returns error for missing source (neither 'session' nor 'source' present)" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "clone", "id" => "spec-clone-no-src", "name" => "no-src-dst"))

        assert_conformance(msgs, "spec-clone-no-src")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "error" in terminal[end]["status"]
    end

    @testset "clone with 'session' field validates source name" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op"      => "clone",
            "id"      => "spec-clone-bad-session",
            "session" => "bad name!",
            "name"    => "dst",
        ))

        assert_conformance(msgs, "spec-clone-bad-session")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "error" in terminal[end]["status"]
        @test !("session-not-found" in terminal[end]["status"])
    end

    @testset "clone rejects unknown type value" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "type-src")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op"     => "clone",
            "id"     => "spec-clone-bad-type",
            "source" => "type-src",
            "name"   => "type-dst",
            "type"   => "medium",
        ))

        assert_conformance(msgs, "spec-clone-bad-type")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "error" in terminal[end]["status"]
        # Session should not have been created
        @test REPLy.lookup_named_session(manager, "type-dst") === nothing
    end

    @testset "deprecated clone-session response does not include new-session key" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "compat-src-schema")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op"     => "clone-session",
            "id"     => "compat-schema-check",
            "source" => "compat-src-schema",
            "name"   => "compat-dst-schema",
        ))

        assert_conformance(msgs, "compat-schema-check")
        resp = filter(m -> haskey(m, "session"), msgs)
        @test !isempty(resp)
        @test !haskey(resp[1], "new-session")  # deprecated op does not include spec key
        @test haskey(resp[1], "session")
    end
end

@testset "close op: spec-compliant schema (REPLy_jl-db4)" begin
    @testset "close accepts 'session' field as session identifier (name alias)" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "spec-close-target")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close", "id" => "spec-close-session-field", "session" => "spec-close-target"))

        assert_conformance(msgs, "spec-close-session-field")
        @test REPLy.lookup_named_session(manager, "spec-close-target") === nothing
        @test isempty(REPLy.list_named_sessions(manager))
    end

    @testset "close accepts 'session' field as session identifier (UUID)" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "spec-close-uuid-target")
        uuid = REPLy.session_id(session)
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close", "id" => "spec-close-uuid-field", "session" => uuid))

        assert_conformance(msgs, "spec-close-uuid-field")
        @test REPLy.lookup_named_session(manager, uuid) === nothing
        @test REPLy.lookup_named_session(manager, "spec-close-uuid-target") === nothing
    end

    @testset "close 'session' field takes priority over 'name' when both present" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "priority-target")
        REPLy.create_named_session!(manager, "priority-other")
        handler = REPLy.build_handler(; manager=manager)

        # 'session' should win; 'priority-other' should survive
        msgs = handler(Dict(
            "op"      => "close",
            "id"      => "spec-close-priority",
            "session" => "priority-target",
            "name"    => "priority-other",
        ))

        assert_conformance(msgs, "spec-close-priority")
        @test REPLy.lookup_named_session(manager, "priority-target") === nothing
        @test REPLy.lookup_named_session(manager, "priority-other") !== nothing
    end

    @testset "close falls back to 'name' when 'session' field is absent (backward compat)" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "compat-name-target")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close", "id" => "spec-close-name-compat", "name" => "compat-name-target"))

        assert_conformance(msgs, "spec-close-name-compat")
        @test REPLy.lookup_named_session(manager, "compat-name-target") === nothing
    end

    @testset "close requires either 'session' or 'name' field (neither present is an error)" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close", "id" => "spec-close-no-field"))

        assert_conformance(msgs, "spec-close-no-field")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "error" in terminal[end]["status"]
    end

    @testset "close 'session' field validates the identifier before lookup" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close", "id" => "spec-close-bad-session", "session" => "bad name!"))

        assert_conformance(msgs, "spec-close-bad-session")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "error" in terminal[end]["status"]
        @test !("session-not-found" in terminal[end]["status"])
    end

    @testset "close returns error for non-existent session via 'session' field" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "close", "id" => "spec-close-ghost-session", "session" => "no-such-session"))

        assert_conformance(msgs, "spec-close-ghost-session")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "error" in terminal[end]["status"]
        @test "session-not-found" in terminal[end]["status"]
    end

    @testset "deprecated close-session still requires 'name' field only" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "dep-close-target")
        handler = REPLy.build_handler(; manager=manager)

        # With 'name' field — should work
        msgs = handler(Dict("op" => "close-session", "id" => "dep-close-with-name", "name" => "dep-close-target"))
        assert_conformance(msgs, "dep-close-with-name")
        @test REPLy.lookup_named_session(manager, "dep-close-target") === nothing
    end

    @testset "deprecated close-session does not accept 'session' field as fallback" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "dep-no-session-field")
        handler = REPLy.build_handler(; manager=manager)

        # Providing 'session' but not 'name' must fail for close-session (name-only op)
        msgs = handler(Dict("op" => "close-session", "id" => "dep-close-session-field", "session" => "dep-no-session-field"))
        assert_conformance(msgs, "dep-close-session-field")
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "error" in terminal[end]["status"]
        # Session must still be intact
        @test REPLy.lookup_named_session(manager, "dep-no-session-field") !== nothing
    end

    @testset "op_info for 'close' lists 'session' as required, 'name' as optional" begin
        mw = REPLy.SessionOpsMiddleware()
        desc = REPLy.descriptor(mw)
        close_info = desc.op_info["close"]
        @test "session" in close_info["requires"]
        @test "name" in close_info["optional"]
        @test !("name" in close_info["requires"])
        @test !("session" in close_info["optional"])
    end
end
