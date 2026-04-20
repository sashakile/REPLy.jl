@testset "integration: session ops (clone, close, ls-sessions)" begin
    @testset "full lifecycle: create, eval, clone, eval-in-clone, ls, close" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        # Step 1: create a named session and eval in it
        REPLy.create_named_session!(manager, "workspace")
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "lifecycle-eval-1",
            "code" => "state = :initialized",
            "session" => "workspace",
        ))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test !isempty(value_msg)
        @test value_msg[1]["value"] == ":initialized"

        # Step 2: clone the session
        msgs = handler(Dict(
            "op" => "clone-session",
            "id" => "lifecycle-clone",
            "source" => "workspace",
            "name" => "workspace-fork",
        ))
        assert_conformance(msgs, "lifecycle-clone")

        # Step 3: eval in the clone — should see the cloned binding
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "lifecycle-eval-clone",
            "code" => "state",
            "session" => "workspace-fork",
        ))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test value_msg[1]["value"] == ":initialized"

        # Step 4: mutate clone and verify isolation
        handler(Dict(
            "op" => "eval",
            "id" => "lifecycle-mutate-clone",
            "code" => "state = :forked",
            "session" => "workspace-fork",
        ))
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "lifecycle-check-orig",
            "code" => "state",
            "session" => "workspace",
        ))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test value_msg[1]["value"] == ":initialized"  # original unchanged

        # Step 5: ls-sessions — should see both
        msgs = handler(Dict("op" => "ls-sessions", "id" => "lifecycle-ls"))
        sessions_msg = filter(m -> haskey(m, "sessions"), msgs)
        names = [s["name"] for s in sessions_msg[1]["sessions"]]
        @test "workspace" in names
        @test "workspace-fork" in names

        # Step 6: close the clone
        msgs = handler(Dict(
            "op" => "close-session",
            "id" => "lifecycle-close",
            "name" => "workspace-fork",
        ))
        assert_conformance(msgs, "lifecycle-close")

        # Step 7: verify clone is gone, original remains
        msgs = handler(Dict("op" => "ls-sessions", "id" => "lifecycle-ls-after"))
        sessions_msg = filter(m -> haskey(m, "sessions"), msgs)
        names = [s["name"] for s in sessions_msg[1]["sessions"]]
        @test "workspace" in names
        @test !("workspace-fork" in names)

        # Step 8: eval in closed session returns session-not-found
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "lifecycle-eval-closed",
            "code" => "1 + 1",
            "session" => "workspace-fork",
        ))
        terminal = filter(m -> haskey(m, "status"), msgs)
        @test "session-not-found" in terminal[end]["status"]
    end

    @testset "ls-sessions returns conformant response" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "s1")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "ls-sessions", "id" => "ls-conform"))
        assert_conformance(msgs, "ls-conform")
    end

    @testset "close-session returns conformant response" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "doomed")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "close-session",
            "id" => "close-conform",
            "name" => "doomed",
        ))
        assert_conformance(msgs, "close-conform")
    end

    @testset "clone-session returns conformant response" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "clonable")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "clone-session",
            "id" => "clone-conform",
            "source" => "clonable",
            "name" => "cloned",
        ))
        assert_conformance(msgs, "clone-conform")
    end

    @testset "ephemeral sessions unaffected by session ops" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "named-one")
        handler = REPLy.build_handler(; manager=manager)

        # Ephemeral eval before
        @test REPLy.session_count(manager) == 0
        handler(Dict("op" => "eval", "id" => "eph-before", "code" => "1"))
        @test REPLy.session_count(manager) == 0

        # Session ops
        handler(Dict("op" => "ls-sessions", "id" => "eph-ls"))
        handler(Dict(
            "op" => "clone-session",
            "id" => "eph-clone",
            "source" => "named-one",
            "name" => "named-two",
        ))
        handler(Dict("op" => "close-session", "id" => "eph-close", "name" => "named-two"))

        # Ephemeral count still zero
        @test REPLy.session_count(manager) == 0

        # Ephemeral eval after — still works
        msgs = handler(Dict("op" => "eval", "id" => "eph-after", "code" => "2 + 3"))
        value_msg = filter(m -> haskey(m, "value"), msgs)
        @test value_msg[1]["value"] == "5"
        @test REPLy.session_count(manager) == 0
    end
end
