@testset "trusted session mode" begin
    @testset "create trusted session — backed by Main" begin
        manager = REPLy.SessionManager()
        s = REPLy.create_named_session!(manager, "t1"; trusted=true)
        @test REPLy.is_trusted(s) == true
        @test s.session_mod === Main
        @test REPLy.session_module_name(s) == "Main"
    end

    @testset "default (untrusted) session uses anonymous module" begin
        manager = REPLy.SessionManager()
        s = REPLy.create_named_session!(manager, "u1")
        @test REPLy.is_trusted(s) == false
        @test s.session_mod !== Main
        @test REPLy.session_module_name(s) == "<anonymous>"
    end

    @testset "new-session via handler with trusted:true" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "new-session", "id" => "ns1",
            "name" => "trusted-via-handler", "trusted" => true,
        ))

        @test any(m -> get(m, "trusted", false) == true, msgs)
        @test msgs[end]["status"] == ["done"]

        s = REPLy.lookup_named_session(manager, "trusted-via-handler")
        @test !isnothing(s)
        @test REPLy.is_trusted(s) == true
        @test s.session_mod === Main
    end

    @testset "new-session with trusted:false (explicit default)" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "new-session", "id" => "ns2",
            "name" => "untrusted-via-handler", "trusted" => false,
        ))

        @test msgs[end]["status"] == ["done"]
        s = REPLy.lookup_named_session(manager, "untrusted-via-handler")
        @test !isnothing(s)
        @test REPLy.is_trusted(s) == false
        @test s.session_mod !== Main
    end

    @testset "new-session without trusted field defaults to false" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "new-session", "id" => "ns3", "name" => "default",
        ))

        @test msgs[end]["status"] == ["done"]
        s = REPLy.lookup_named_session(manager, "default")
        @test REPLy.is_trusted(s) == false
    end

    @testset "new-session rejects non-boolean trusted" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict(
            "op" => "new-session", "id" => "ns-bad",
            "name" => "bad", "trusted" => "yes",
        ))

        @test "error" in msgs[end]["status"]
        @test any(m -> contains(get(m, "err", ""), "trusted"), msgs)
    end

    @testset "ls-sessions shows trusted:true for trusted sessions" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "trusted-1"; trusted=true)
        REPLy.create_named_session!(manager, "normal-1")
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "ls-sessions", "id" => "ls-trusted"))
        sessions_msg = filter(m -> haskey(m, "sessions"), msgs)
        @test length(sessions_msg) == 1
        sessions = sessions_msg[1]["sessions"]
        @test length(sessions) == 2

        trusted_entry = filter(s -> get(s, "name", "") == "trusted-1", sessions)
        @test length(trusted_entry) == 1
        @test trusted_entry[1]["trusted"] == true
        @test trusted_entry[1]["module"] == "Main"

        normal_entry = filter(s -> get(s, "name", "") == "normal-1", sessions)
        @test length(normal_entry) == 1
        @test normal_entry[1]["trusted"] == false
        @test normal_entry[1]["module"] == "<anonymous>"
    end

    @testset "trusted session: eval works (include, bare using, Main.eval)" begin
        manager = REPLy.SessionManager()
        s = REPLy.create_named_session!(manager, "trusted-eval"; trusted=true)
        @test REPLy.is_trusted(s) == true

        Core.eval(s.session_mod, :(x = 42))
        @test Core.eval(s.session_mod, :(x)) == 42

        @test Core.eval(Main, :(x)) == 42
    end

    @testset "closing a trusted session does not reset Main" begin
        manager = REPLy.SessionManager()
        s = REPLy.create_named_session!(manager, "trusted-close"; trusted=true)
        Core.eval(Main, :(y = 100))

        REPLy.destroy_named_session!(manager, REPLy.session_id(s))

        @test Core.eval(Main, :(y)) == 100
        @test REPLy.lookup_named_session(manager, "trusted-close") === nothing
    end

    @testset "multiple trusted sessions share Main" begin
        manager = REPLy.SessionManager()
        s1 = REPLy.create_named_session!(manager, "t1"; trusted=true)
        s2 = REPLy.create_named_session!(manager, "t2"; trusted=true)

        @test s1.session_mod === Main
        @test s2.session_mod === Main
        @test REPLy.is_trusted(s1) == true
        @test REPLy.is_trusted(s2) == true
    end

    @testset "create_named_session_if_within_limit! with trusted" begin
        manager = REPLy.SessionManager()
        s = REPLy.create_named_session_if_within_limit!(manager, "lim-trusted", 10; trusted=true)
        @test !isnothing(s)
        @test REPLy.is_trusted(s) == true
        @test s.session_mod === Main
    end

    @testset "get_or_create_named_session! with trusted" begin
        manager = REPLy.SessionManager()
        s = REPLy.get_or_create_named_session!(manager, "get-or-create-trusted"; trusted=true)
        @test REPLy.is_trusted(s) == true
        @test s.session_mod === Main
    end

    @testset "describe middleware includes trusted field in new-session doc" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        msgs = handler(Dict("op" => "describe", "id" => "desc-trusted"))
        desc_msg = filter(m -> haskey(m, "ops"), msgs)
        @test length(desc_msg) == 1
        ops = desc_msg[1]["ops"]
        @test haskey(ops, "new-session")
        new_sess_doc = ops["new-session"]["doc"]
        @test occursin("trusted", new_sess_doc)
    end
end
